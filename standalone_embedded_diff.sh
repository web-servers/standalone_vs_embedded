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
m) MAVEN_ZIP=${OPTARG};;
s) STANDALONE_ZIP=${OPTARG};;
w) WORKSPACE=${OPTARG};;
esac
done

WORKSPACE="${WORKSPACE:-/tmp/standalone_embedded_diff}"

# Print help
if [ "$STANDALONE_ZIP" == "" ] || [ "$MAVEN_ZIP" == "" ]; then
  echo "This script looks for differences between standalone and embedded tomcats."
  echo
  echo "Usage:"
  echo "     sh standalone_embedded_diff.sh -s <tomcat standalone zip> -m <maven repo zip> [-w <workspace_dir>]"
  exit 1
fi

# Checks MD5 sums 
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
      REPO_MISSING+=(["$standalone_jar"]="$repo_class:")
      continue
    fi    

    if check_hash_sums $repo_class $class; then
      REPO_CHECKED_CLASSES+=($repo_class)
    else
      DIFFERENCES+=(["$standalone_jar"]="$class:")
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
      REPO_ADDITIONAL+=(["$repo_jar"]="$repo_class:")
      continue
    fi
  done

  rm -rf $b_dir/*

done

# Outputs formating (stdout and test report combined)
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

# Test report file
f=$WORKSPACE/TEST-report.xml

echo '<testsuite name="Standalone_vs_Embedded" time="0" tests="4" errors="0" skipped="0" failures="'$failures'">' > $f
echo '  <testcase name="Different Classes" time="0">' >> $f

# Report differences
echo
echo DIFFERENCES:
if [[ ${#DIFFERENCES[@]} > 0 ]]; then 
  echo '    <failure message="Archives differ in some packages">' >> $f

  for diff in "${!DIFFERENCES[@]}"; do
    different_classes_count=`echo ${DIFFERENCES[$diff]} | tr ":" "\n" | grep -c ".class"`  
    package_classes_count=`unzip -l $diff | grep -c ".class"`
    diff_base=`basename $diff`

    if [ "$different_classes_count" == "$package_classes_count" ]; then
      printf "\t%-60s %s\n" $diff_base "ALL" | tee -a $f
    else
      printf "\t%-60s %s\n" $diff_base "$different_classes_count/$package_classes_count" | tee -a $f
    fi
  done
  echo '    </failure>' >> $f
fi

echo '  </testcase>' >> $f
echo '  <testcase name="Repo Missing Packages" time="0">' >> $f

# Report missing files in repo
echo
echo REPO MISSING:
if [[ ${#REPO_MISSING[@]} > 0 ]]; then
  echo '    <failure message="Maven repository archive does not contain some packages from standalone archive">' >> $f
  for missing in ${!REPO_MISSING[@]}; do
    different_classes_count=`echo ${REPO_MISSING[$missing]} | tr ":" "\n" | grep -c ".class"`  
    package_classes_count=`unzip -l $missing | grep -c ".class"`
    missing_base=`basename $missing`

    if [ "$different_classes_count" == "$package_classes_count" ]; then
      printf "\t%-60s %s\n"  $missing_base "ALL" | tee -a $f 
    else
      printf "\t%-60s %s\n"  $missing_base "$different_classes_count/$package_classes_count" | tee -a $f

      for i in `echo ${REPO_MISSING[$missing]} | tr ":" "\n"`; do
        echo ${i#*$a_dir} &>> $WORKSPACE/REPO_MISSING_$missing_base.txt
      done
    fi
  done
  echo '    </failure>' >> $f
fi

echo '  </testcase>' >> $f
echo '  <testcase name="Repo Additional Packages" time="0">' >> $f 

# Report additional files in repo
echo
echo REPO ADDITIONAL:
if [[ ${#REPO_ADDITIONAL[@]} > 0 ]]; then
  echo '    <failure message="Maven repository archive contains some additional packages">' >> $f
  for additional in ${!REPO_ADDITIONAL[@]}; do
    different_classes_count=`echo ${REPO_ADDITIONAL[$additional]} | tr ":" "\n" | grep -c ".class"`
    package_classes_count=`unzip -l $additional | grep -c ".class"`
    additional_base=`basename $additional`

    if [ "$different_classes_count" == "$package_classes_count" ]; then
      printf "\t%-60s %s %s\n" $additional_base "ALL" | tee -a $f
    else
      printf "\t%-60s %s\n"  $additional_base "$different_classes_count/$package_classes_count" | tee -a $f

      for i in `echo ${REPO_ADDITIONAL[$additional]} | tr ":" "\n"`; do
        echo ${i#*$a_dir} &>> $WORKSPACE/REPO_ADDITIONAL_$additional_base.txt
      done
    fi
  done
  echo '    </failure>' >> $f
fi

echo '  </testcase>' >> $f
echo '  <testcase name="Duplicated Classes" time="0">' >> $f

# Report duplicated classes
echo
echo DUPLICATD CLASSES in standalone Tomcat:
if [[ ${#DUPLICATED_CLASSES[@]} > 0 ]]; then
  echo '    <failure message="Standalone archive contains some classes multiple times">' >> $f
  for duplicated in ${!DUPLICATED_CLASSES[@]}; do
    printf "\t%s\n" ${DUPLICATED_CLASSES[$duplicated]#*$a_dir} | tee -a $f
  done
  echo '    </failure>' >> $f
fi

echo '  </testcase>' >> $f
echo '</testsuite>' >> $f

echo 
echo Report stored to $f
