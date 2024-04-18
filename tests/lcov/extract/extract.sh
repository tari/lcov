#!/bin/bash
set +x

CLEAN_ONLY=0
COVER=

PARALLEL='--parallel 0'
PROFILE="--profile"
COVER_DB='cover_db'
LOCAL_COVERAGE=1
KEEP_GOING=0
while [ $# -gt 0 ] ; do

    OPT=$1
    shift
    case $OPT in

        --clean | clean )
            CLEAN_ONLY=1
            ;;

        -v | --verbose | verbose )
            set -x
            ;;

        --keep-going )
            KEEP_GOING=1
            ;;

        --coverage )
            #COVER="perl -MDevel::Cover "
            if [[ "$1"x != 'x' &&  $1 != "-"* ]] ; then
               COVER_DB=$1
               LOCAL_COVERAGE=0
               shift
            fi
            COVER="perl -MDevel::Cover=-db,$COVER_DB,-coverage,statement,branch,condition,subroutine "
            ;;

        --home | -home )
            LCOV_HOME=$1
            shift
            if [ ! -f $LCOV_HOME/bin/lcov ] ; then
                echo "LCOV_HOME '$LCOV_HOME' does not exist"
                exit 1
            fi
            ;;

        --no-parallel )
            PARALLEL=''
            ;;

        --no-profile )
            PROFILE=''
            ;;

        * )
            echo "Error: unexpected option '$OPT'"
            exit 1
            ;;
    esac
done

if [[ "x" == ${LCOV_HOME}x ]] ; then
       if [ -f ../../../bin/lcov ] ; then
           LCOV_HOME=../../..
       else
           LCOV_HOME=../../../../releng/coverage/lcov
       fi
fi
LCOV_HOME=`(cd ${LCOV_HOME} ; pwd)`

if [[ ! ( -d $LCOV_HOME/bin && -d $LCOV_HOME/lib && -x $LCOV_HOME/bin/genhtml && ( -f $LCOV_HOME/lib/lcovutil.pm || -f $LCOV_HOME/lib/lcov/lcovutil.pm ) ) ]] ; then
    echo "LCOV_HOME '$LCOV_HOME' seems not to be invalid"
    exit 1
fi

export PATH=${LCOV_HOME}/bin:${LCOV_HOME}/share:${PATH}
export MANPATH=${MANPATH}:${LCOV_HOME}/man

if [ 'x' == "x$GENHTML_TOOL" ] ; then
    GENHTML_TOOL=${LCOV_HOME}/bin/genhtml
    LCOV_TOOL=${LCOV_HOME}/bin/lcov
    GENINFO_TOOL=${LCOV_HOME}/bin/geninfo
fi

#use geninfo for capture - so we can collect coverage info
CAPTURE=$GENINFO_TOOL 
#CAPTURE="$LCOV_TOOL --capture --directory"

ROOT=`pwd`
PARENT=`(cd .. ; pwd)`

LCOV_OPTS="--rc lcov_branch_coverage=1 $PARALLEL $PROFILE"
# gcc/4.8.5 (and possibly other old versions) generate inconsistent line/function data
IFS='.' read -r -a VER <<< `gcc -dumpversion`
if [ "${VER[0]}" -lt 5 ] ; then
    IGNORE="--ignore inconsistent"
    # and filter exception branches to avoid spurious differences for old compiler
    FILTER='--filter branch'
fi

rm -rf *.gcda *.gcno a.out *.info* *.txt* *.json dumper* testRC *.gcov *.gcov.* *.log *.o
rm -rf rcOptBug

if [ -d separate ] ; then
    chmod -R ug+rxw separate
    rm -rf separate
fi

if [ "x$COVER" != 'x' ] && [ 0 != $LOCAL_COVERAGE ] ; then
    cover -delete
fi

if [[ 1 == $CLEAN_ONLY ]] ; then
    exit 0
fi

if ! type g++ >/dev/null 2>&1 ; then
        echo "Missing tool: g++" >&2
        exit 2
fi

g++ -std=c++1y --coverage extract.cpp
if [ 0 != $? ] ; then
    echo "Error:  unexpected error from g++"
    exit 1
fi
# gcc 5 and 6 just do not work for initial capture
if [[ "${VER[0]}" -gt 4 && "${VER[0]}" -lt 7 ]] ; then
    # no data generated by initial capture
    IGNORE_EMPTY="--ignore empty"
    NO_INITIAL_CAPTURE=1
fi
if [ "${VER[0]}" -lt 8 ] ; then
    # cannot generate branch data unless 'intermediate'
    IGNORE_USAGE="--ignore usage"
    DERIVE_END='--rc derive_function_end_line=0'
fi
$COVER $CAPTURE . $LCOV_OPTS --initial -o initial.info $IGNORE_EMPTY $IGNORE_USAGE
if [ 0 != $? ] ; then
    echo "Error:  unexpected error code from lcov --initial"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

gcc -c --coverage unused.c
if [ 0 != $? ] ; then
    echo "Error:  unexpected error from gcc"
    exit 1
fi
# capture 'all' - which will pick up the unused file
$COVER $CAPTURE . $LCOV_OPTS --all -o all_initial.info $IGNORE_EMPTY $IGNORE_USAGE
if [ 0 != $? ] ; then
    echo "Error:  unexpected error code from lcov --capture --all"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

if [ "$NO_INITIAL_CAPTURE" != 1 ] ; then
    # does the result contain file 'uused'
    grep -E "SF:.+unused.c$" all_initial.info
    if [ $? != 0 ] ; then
        echo "Error: did not find 'unused'"
        if [ $KEEP_GOING == 0 ] ; then
            exit 1
        fi
    fi
fi

./a.out 1
if [ 0 != $? ] ; then
    echo "Error:  unexpected error return from a.out"
    exit 1
fi

$COVER $CAPTURE . $LCOV_OPTS -o external.info $FILTER $IGNORE
if [ 0 != $? ] ; then
    echo "Error:  unexpected error code from lcov --capture"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

$COVER $LCOV_TOOL $LCOV_OPTS --list external.info $FILTER $IGNORE
if [ 0 != $? ] ; then
    echo "Error:  unexpected error code from lcov --list"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

# how many files reported?
COUNT=`grep -c SF: external.info`
if [ $COUNT == '1' ] ; then
    echo "expected at least 2 files in external.info - found $COUNT"
    exit 1
fi

$COVER $CAPTURE . $LCOV_OPTS --no-external -o internal.info

$COVER $LCOV_TOOL $LCOV_OPTS --list internal.info

COUNT=`grep -c SF: internal.info`
if [ $COUNT != '1' ] ; then
    echo "expected 1 file in internal.info - found $COUNT"
    exit 1
fi

# capture again, using --all - should pick up 'unused.c'
$COVER $CAPTURE . $LCOV_OPTS --all -o all_internal.info --no-external $FILTER $IGNORE
if [ 0 != $? ] ; then
    echo "Error:  unexpected error code from lcov --capture --all"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
if [ "$NO_INITIAL_CAPTURE" != 1 ] ; then
    # does the result contain file 'uused'
    grep -E "SF:.+unused.c$" all_internal.info
    if [ $? != 0 ] ; then
        echo "Error: did not find 'unused'"
        if [ $KEEP_GOING == 0 ] ; then
            exit 1
        fi
    fi
    if [ "${VER[0]}" -gt 7 ] ; then
        # should have found the branch in 'unused.c'
        C=`grep -c BRDA: all_internal.info`
        if [ "$C" != 18 ] ; then
            echo "Error: did not find 'unused'"
            if [ $KEEP_GOING == 0 ] ; then
                exit 1
            fi
        fi
    fi
fi

# test some config file options

# error message for missing env var in RC file
$COVER $LCOV_TOOL $IGNORE --capture -d . $LCOV_OPTS -o err1.info --config-file envVar.rc 2>&1 | tee err1.log
if [ ${PIPESTATUS[0]} == 0 ] ; then
    echo "expected 'ERROR_USAGE' - did not find"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

# skip ignore error
$COVER $LCOV_TOOL $IGNORE --capture -d . $LCOV_OPTS -o ignore1.info --config-file envVar.rc --ignore usage
if [ 0 != $? ] ; then
    echo "expected to ignore 'ERROR_USAGE'"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

export ENV_IGNORE='empty'
# error message for missing env var in RC file
$COVER $LCOV_TOOL $IGNORE --capture -d . $LCOV_OPTS -o setVar.info --config-file envVar.rc
if [ 0 != $? ] ; then
    echo "expected to set var from env - but didn't"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

# error message for missing env var in RC file
$COVER $LCOV_TOOL $IGNORE --capture -d . $LCOV_OPTS -o err2.info --config-file envErr.rc  2>&1 | tee err2.log
if [ ${PIPESTATUS[0]} == 0 ] ; then
    echo "expected mssing value error - not found"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

# ignore the error
$COVER $LCOV_TOOL $IGNORE --capture -d . $LCOV_OPTS -o ignore2.info --config-file envErr.rc --ignore format
if [ 0 != $? ] ; then
    echo "expected to ignore error - but didn't"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi


# use legacy RC 'geninfo_adjust_src_path option (had been a bug)
$COVER $CAPTURE . $LCOV_OPTS --no-external -o rcOptBug $PARALLEL $PROFILE --rc "geninfo_adjust_src_path='/tmp/foo => /build/bar'" --ignore unused 2>&1 | tee rcOptBug.log
if [ 0 != $? ] ; then
    echo "Error:  extract with RC option failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
grep -E "'substitute' pattern .+ is unused" rcOptBug.log
if [ 0 != $? ] ; then
    echo "Error:  missing RC pattern unused message"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
grep -E "RC option 'geninfo_adjust_src_path' is deprecated" rcOptBug.log
if [ 0 != $? ] ; then
    echo "Error:  missing RC pattern unused message"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi


# workaround:  depending on compiler verision, we see a coverpoint on the
#  close brace line (gcc/6 for example) or we don't (gcc/10 for example)
BRACE_LINE='^DA:28'
MARKER_LINES=`grep -v $BRACE_LINE internal.info | grep -c "^DA:"`

# check 'no-markers':  is the excluded line back?
$COVER $CAPTURE . $LCOV_OPTS --no-external -o nomarkers.info --no-markers
if [ $? != 0 ] ; then
    echo "error return from extract no-markers"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
NOMARKER_LINES=`grep -v $BRACE_LINE nomarkers.info | grep -c "^DA:"`
NOMARKER_BRANCHES=`grep -c "^BRDA:" nomarkers.info`
if [ $NOMARKER_LINES != '13' ] ; then
    echo "did not honor --no-markers expected 13 found $NOMARKER_LINES"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

# override excl_line start/stop - and make sure we didn't match
$COVER $CAPTURE . $LCOV_OPTS --no-external -o excl.info --rc lcov_excl_start=nomatch_start --rc lcov_excl_stop=nomatch_end
if [ $? != 0 ] ; then
    echo "error return from marker override"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
EXCL_LINES=`grep -v $BRACE_LINE excl.info | grep -c "^DA:"`
if [ $EXCL_LINES != $NOMARKER_LINES ] ; then
    echo "did not honor marker override: expected $NOMARKER_LINES found $EXCL_LINES"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

# override excl_br line start/stop - and make sure we match match
$COVER $CAPTURE . $LCOV_OPTS --no-external -o exclbr.info --rc lcov_excl_br_start=TEST_BRANCH_START --rc lcov_excl_br_stop=TEST_BRANCH_STOP
if [ $? != 0 ] ; then
    echo "error return from branch marker override"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
EXCL_BRANCHES=`grep -c "^BRDA:" exclbr.info`

if [ $EXCL_BRANCHES -ge $NOMARKER_BRANCHES ] ; then
    echo "did not honor br marker override: expected $NOMARKER_BRANCHES to be larger than $EXCL_BRANCHES"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

# override excl_br line start/stop - and make sure we match match
$COVER $CAPTURE . $LCOV_OPTS --no-external -o exclbrline.info --rc lcov_excl_br_line=TEST_BRANCH_LINE
if [ $? != 0 ] ; then
    echo "error return from branch line marker override"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
EXCL_LINE_BRANCHES=`grep -c "^BRDA:" exclbrline.info`

if [ $EXCL_LINE_BRANCHES != $EXCL_BRANCHES ] ; then
    echo "did not honor br line marker override: expected $EXCL_BRANCHES foune $EXCL_LINE_BRANCHES"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi



# check to see if "--omit-lines" works properly...
$COVER $CAPTURE . $LCOV_OPTS --no-external --omit-lines '\s+std::string str.+' -o omit.info

if [ 0 != $? ] ; then
    echo "Error:  unexpected error code from lcov --omit"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

BRACE_LINE="DA:28"
# a bit of a hack:  gcc/10 doesn't put a DA entry on the closing brace
COUNT=`grep -v $BRACE_LINE omit.info | grep -c ^DA:`
if [ $COUNT != '11' ] ; then
    echo "expected 11 DA entries in 'omit.info' - found $COUNT"
    exit 1
fi

# check to see if "--omit-lines" works fails if no match
$COVER $CAPTURE . $LCOV_OPTS --no-external --omit-lines 'xyz\s+std::string str.+' -o omitErr.info

if [ 0 == $? ] ; then
    echo "Error:  did not see expected error code from lcov --omit"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

$COVER $CAPTURE . $LCOV_OPTS --no-external --omit-lines 'xyz\s+std::string str.+' -o omitWarn.info --ignore unused

if [ 0 != $? ] ; then
    echo "Error:  unexpected expected error code from lcov --omit --ignore.."
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
COUNT=`grep -v $BRACE_LINE omitWarn.info | grep -c ^DA:`
if [ $COUNT != '12' ] ; then
    echo "expected 12 DA entries in 'omitWarn.info' - found $COUNT"
    exit 1
fi

# try again, with rc file instead
echo "omit_lines = ^std::string str.+\$" > testRC # no space at start ofline
echo "omit_lines = ^\\s+std::string str.+\$" >> testRC
#should fail due to no match...
$COVER $CAPTURE . $LCOV_OPTS --no-external --config-file testRC -o rc_omitErr.info

if [ 0 == $? ] ; then
    echo "Error:  did not see expected error code from lcov --config with bad omit"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
echo "ignore_errors = unused" >> testRC
echo "ignore_errors = empty" >> testRC

$COVER $CAPTURE . $LCOV_OPTS --no-external --config-file testRC -o rc_omitWarn.info

if [ 0 != $? ] ; then
    echo "Error:  saw unexpected error code from lcov --config with ignored bad omit"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
COUNT=`grep -v $BRACE_LINE  rc_omitWarn.info | grep -c ^DA:`
if [ $COUNT != '11' ] ; then
    echo "expected 11 DA entries in 'rc_omitWarn.info' - found $COUNT"
    exit 1
fi

# test with checksum..
$COVER $CAPTURE . $LCOV_OPTS --no-external -o checksum.info --checksum
if [ $? != 0 ] ; then
    echo "capture with checksum failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
# read file with matching checksum...
$COVER $LCOV_TOOL $LCOV_OPTS --summary checksum.info --checksum
if [ $? != 0 ] ; then
    echo "summary with checksum failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
#munge the checksum in the outpt file
perl -i -pe 's/DA:6,1.+/DA:6,1,abcde/g' < checksum.info > mismatch.info
$COVER $LCOV_TOOL $LCOV_OPTS --summary mismatch.info --checksum
if [ $? == 0 ] ; then
    echo "summary with mismatched checksum expected to fail"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

perl -i -pe 's/DA:6,1.+/DA:6,1/g' < checksum.info > missing.info
$COVER $LCOV_TOOL $LCOV_OPTS --summary missing.info --checksum
if [ $? == 0 ] ; then
    echo "summary with missing checksum expected to fail"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

# check case when build dir and GCOV_PREFIX directory are not the same -
#  so .gcno and .gcda files are in different places
export DEPTH=0
BASE=`pwd`
while [ $BASE != '/' ] ; do
  echo $BASE
  BASE=`dirname $BASE`
  let DEPTH=$DEPTH+1
done
echo "found depth $DEPTH"
let STRIP=$DEPTH+2

mkdir -p separate/build
mkdir -p separate/run
mkdir -p separate/copy
( cd separate/build ; g++ -std=c++1y --coverage ../../extract.cpp )
cp separate/build/*.gcno separate/copy
# make unwritable - so we don't allow lcov to write temporaries
#  this emulates what happens when the build job is owned by one user,
#  the test job by another, and a third person is trying to create coverage reports
chmod ugo-w separate/build
chmod ugo-w separate/copy
if [ 0 != $? ] ; then
    echo "Error:  no .gcno files to copy"
    exit 1
fi

( cd separate/run ; GCOV_PREFIX=my/test GCOV_PREFIX_STRIP=$STRIP ../build/a.out 1 )
if [ 0 != $? ] ; then
    echo "Error:  execution failed"
    exit 1
fi
mkdir separate/run/my/test/no_read
chmod ugo-w separate/run
$COVER $CAPTURE separate/run/my/test --branch-coverage $PARALLEL $PROFILE --build-directory separate/build  -o separate.info $FILTER $IGNORE
if [ 0 != $? ] ; then
    echo "Error:  extract failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
$COVER $CAPTURE separate/run/my/test --branch-coverage $PARALLEL $PROFILE --build-directory separate/copy  -o copy.info $FILTER $IGNORE
if [ 0 != $? ] ; then
    echo "Error:  extract from copy failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

# use --resolve-script instead - simply echo the right value of the gcno file
$COVER $CAPTURE  separate/run/my/test --branch-coverage $PARALLEL $PROFILE --resolve-script ./fakeResolve.sh --resolve-script separate/copy/extract.gcno -o resolve.info $FILTER $IGNORE
if [ 0 != $? ] ; then
    echo "Error:  extract with resolve-script failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

# captured data from GCOV_PREFIX result should be identical to vanilla build
for d in separate.info copy.info resolve.info ; do
    diff external.info $d
    if [ $? != 0 ] ; then
        echo "Error: unexpected GCOV_PREFIX result '$d'"
        exit 1
    fi
done


# trigger an error from an unreadable directory..
chmod ugo-rx separate/run/my/test/no_read
$COVER $CAPTURE separate/run/my/test --branch-coverage $PARALLEL $PROFILE --build-directory separate/copy -o unreadable.info $FILTER $IGNORE 2>&1 | tee err.log
if [ 0 == ${PIPESTATUS[0]} ] ; then
    echo "Error:  expected fail from unreadable dir"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

grep "error in 'find" err.log
if [ 0 != $? ] ; then
    echo "expected error not found"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

$COVER $CAPTURE separate/run/my/test --branch-coverage $PARALLEL $PROFILE --build-directory separate/copy -o unreadable.info $FILTER $IGNORE --ignore utility 2>&1 | tee warn.log
if [ 0 != ${PIPESTATUS[0]} ] ; then
    echo "Error:  extract from unreadable failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
grep "error in 'find" warn.log
if [ 0 != $? ] ; then
    echo "expected warning not found"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

chmod -R ug+rxw separate

# try filtering missing files
sed -e s/extract.cpp/notfound.cpp/ external.info > missing_file.info
$COVER $LCOV_TOOL $LCOV_OPTS -o removeMissing.info -a missing_file.info --filter missing $DERIVE_END
if [ 0 != $? ] ; then
    echo "filter missing failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
grep -E 'SF:.*notfound.cpp' removeMissingb.info
if [ 0 == $? ] ; then
    echo "expected to remove missing file"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

$COVER $LCOV_TOOL $LCOV_OPTS -o removeMissing_cb.info -a missing_file.info --filter missing --resolve-script brokenCallback.pm,live,missing $DERIVE_END
if [ 0 != $? ] ; then
    echo "filter missing callback failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
grep -E 'SF:.*notfound.cpp' removeMissing_cb.info
if [ 0 == $? ] ; then
    echo "expected to remove missing file"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

$COVER $LCOV_TOOL $LCOV_OPTS -o removeMissing_cb2.info -a missing_file.info --filter missing --resolve-script brokenCallback.pm,live,present --ignore source $DERIVE_END
if [ 0 != $? ] ; then
    echo "filter missing callback failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
grep -E 'SF:.*notfound.cpp' removeMissing_cb2.info
if [ 0 != $? ] ; then
    echo "expected to keep file"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi

$COVER $LCOV_TOOL $LCOV_OPTS -o removeMissing_cb3.info -a missing_file.info --filter missing --resolve-script brokenCallback.pm,die --ignore callback $DERIVE_END 2>&1 | tee removeMissing.log
if [ ${PIPESTATUS[0]} != $? ] ; then
    echo "filter missing callback failed"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
grep -E 'SF:.*notfound.cpp' removeMissing_cb3.info
if [ 0 == $? ] ; then
    echo "expected to remove file"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi
grep -E 'resolve.*failed' removeMissing.log
if [ 0 != $? ] ; then
    echo "expected to find messages"
    if [ $KEEP_GOING == 0 ] ; then
        exit 1
    fi
fi


echo "Tests passed"

if [ "x$COVER" != "x" ] && [ $LOCAL_COVERAGE == 1 ]; then
    cover
fi
