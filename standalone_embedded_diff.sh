#!/bin/bash

CHECKED=()
DUPLICATED_CLASSES=()
REPO_CHECKED_CLASSES=()

declare -A DIFFERENCES
declare -A REPO_MISSING
declare -A REPO_ADDITIONAL

while getopts d:m:s:w: option
do
case "${option}"
in
d) DIST_DIFF=${OPTARG};;
m) MAVEN_ZIP=${OPTARG};;
s) STANDALONE_ZIP=${OPTARG};;
w) WORKSPACE=${OPTARG};;
esac
done

DIST_DIFF="${DIST_DIFF:-dist-diff2-0.9.1-jar-with-dependencies.jar}"
WORKSPACE="${WORKSPACE:-/tmp/standalone_embedded_diff}"

if [ "$STANDALONE_ZIP" == "" ] || [ "$MAVEN_ZIP" == "" ]; then
  echo "This script looks for differences between standalone and embedded tomcats."
  echo
  echo "Usage:"
  echo "     sh standalone_embedded_diff.sh -s <tomcat standalone zip> -m <maven repo zip> [-d <dist_diff>] [-w <workspace_dir>]"
  exit 1
fi

check_hash_sums () {
  local sum_1=`md5sum $1 | awk '{ print $1 }'`
  local sum_2=`md5sum $2 | awk '{ print $1 }'`

  if [[ "$sum_1" == "$sum_2" ]]; then
    return 0
  else
    return 1
  fi
}

MAVEN_REPO_NAME=`unzip -l $MAVEN_ZIP | sed -n 's/.*\(jboss-web-server-.*-maven-repository\)\/$/\1/p'`

mkdir -p $WORKSPACE
rm -rf $WORKSPACE/*

mkdir $WORKSPACE/standalone $WORKSPACE/repo

# Unzip packages into WORKSPACE
unzip -qq $STANDALONE_ZIP -d $WORKSPACE/standalone
unzip -qq $MAVEN_ZIP -d $WORKSPACE/repo

a_dir=$WORKSPACE"/folderA/"
b_dir=$WORKSPACE"/folderB/"

mkdir $a_dir $b_dir

# Go through jar files from zip distribution
for standalone_jar in $(find $WORKSPACE/standalone -name "*.jar"); do
  s_jar=`basename $standalone_jar`
  pattern=${s_jar%.*}
  repo_jar=""

  for repo_jar in $(find $WORKSPACE/repo -name "*$pattern*.jar"); do
    if [[ ! `basename $repo_jar` = *"source"* ]]; then
       # Check hash sums
       if check_hash_sums $standalone_jar $repo_jar ; then
          CHECKED+=($standalone_jar)
          CHECKED+=($repo_jar)
       fi
    fi
  done
done

# Removes already checked jars
for checked in "${CHECKED[@]}"; do
  rm $checked
done

# Clean up in temporary dirs
rm -rf $a_dir/* $b_dir/*

# Unzips all repo jars
for repo_jar in $(find $WORKSPACE/repo -name "*.jar"); do
  if [[ ! `basename $repo_jar` = *"source"* ]]; then
    unzip -o -qq -d $a_dir $repo_jar "*.class" &> /dev/null
  fi
done

# Go through standalone jars and check all classes
for standalone_jar in $(find $WORKSPACE/standalone -name "*.jar"); do
  unzip -o -qq -d $b_dir $standalone_jar "*.class" &> /dev/null

  s_jar=$(basename $standalone_jar)

  for class in $(find $b_dir -name "*.class"); do
    repo_class="$a_dir/${class#*$b_dir}"

    if [ ! -f $repo_class ]; then
      REPO_MISSING["$s_jar"]="$repo_class"
      continue
    fi    

    if check_hash_sums $repo_class $class; then
      REPO_CHECKED_CLASSES+=($repo_class)
    else
      DIFFERENCES["$standalone_jar"]="$class"
    fi
  done

  # Clean checked package
  rm -rf $b_dir/*
done

# Cleanup checked classes
for checked in "${REPO_CHECKED_CLASSES[@]}"; do
  if [ -f $checked ]; then
    rm "$checked"
  else
    DUPLICATED_CLASSES+=($checked)
  fi
done

rm -rf $b_dir/*

# Look for repo packages which contain additional classes (currently in a_dir)
for repo_jar in $(find $WORKSPACE/repo -name "*.jar"); do
  unzip -o -qq -d $b_dir $repo_jar "*.class" &> /dev/null

  r_jar=$(basename $repo_jar)

  for class in $(find $b_dir -name "*.class"); do
    repo_class="$a_dir/${class#*$b_dir}"

    if [ -f $repo_class ]; then
      REPO_ADDITIONAL["$r_jar"]="$repo_class"
      continue
    fi
  done

  rm -rf $b_dir/*

done

echo
echo DIFFERENCES:
for diff in "${!DIFFERENCES[@]}"; do
  printf "\t%-80s e.g. %s\n" $diff ${DIFFERENCES[$diff]#*$b_dir}
done

echo
echo REPO MISSING:
for missing in ${!REPO_MISSING[@]}; do
  printf "\t%-80s e.g. %s\n"  $missing ${REPO_MISSING[$missing]#*$a_dir}
done

echo
echo REPO ADDITIONAL:
for additional in ${!REPO_ADDITIONAL[@]}; do
  printf "\t%-80s e.g. %s\n"  $additional ${REPO_ADDITIONAL[$additional]#*$a_dir}
done

echo
echo DUPLICATD CLASSES in standalone Tomcat:
for duplicated in ${!DUPLICATED_CLASSES[@]}; do
 printf "\t%s\n" ${DUPLICATED_CLASSES[$duplicated]#*$a_dir}
done

# Prepare report
failures=0

if [[ ${#DIFFERENCES[@]} > 0 ]]; then
  failures=$(($failures + 1))
fi

if [[ ${#REPO_MISSING[@]} > 0 ]]; then
  failures=$(($failures + 1))
fi

if [[ ${#REPO_ADDITIONAL[@]} > 0 ]]; then
  failures=$(($failures + 1))
fi

if [[ ${#DUPLICATED_CLASSES[@]} > 0 ]]; then
  failures=$(($failures + 1))
fi

f=TEST-report.xml

echo '<testsuite name="Standalone vs. Embedded" time="0" tests="4" errors="0" skipped="0" failures="'$failures'">' > $f
echo '  <testcase name="Different Classes" time="0">' >> $f

if [[ ${#DIFFERENCES[@]} > 0 ]]; then 
  for diff in "${!DIFFERENCES[@]}"; do
  echo '    <error type="'$diff ${DIFFERENCES[$diff]#*$b_dir}'"/>' >> $f
done
fi 

echo '  </testcase>' >> $f
echo '  <testcase name="Repo Missing Packages" time="0">' >> $f

if [[ ${#REPO_MISSING[@]} > 0 ]]; then
for missing in ${!REPO_MISSING[@]}; do
  echo '    <error type="'$missing ${REPO_MISSING[$missing]#*$b_dir}'"/>' >> $f
done
fi

echo '  </testcase>' >> $f
echo '  <testcase name="Repo Additional Packages" time="0">' >> $f 

if [[ ${#REPO_ADDITIONAL[@]} > 0 ]]; then
for additional in ${!REPO_ADDITIONAL[@]}; do
  echo '    <error type="'$additional ${REPO_ADDITIONAL[$additional]#*$b_dir}'"/>' >> $f
done
fi

echo '  </testcase>' >> $f
echo '  <testcase name="Duplicated Classes" time="0">' >> $f

if [[ ${#DUPLICATED_CLASSES[@]} > 0 ]]; then
for duplicated in ${!DUPLICATED_CLASSES[@]}; do
  echo '    <error type="'${DUPLICATED_CLASSES[$duplicated]#*$b_dir}'"/>' >> $f
done
fi

echo '  </testcase>' >> $f
echo '</testsuite>' >> $f

echo 
echo Report stored to $f
