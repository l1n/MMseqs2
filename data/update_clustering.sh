#!/bin/bash -e
function fail() {
    echo "Error: $1"
    exit 1
}

function notExists() {
	[ ! -f "$1" ]
}

function abspath() {
    if [ -d "$1" ]; then
        (cd "$1"; pwd)
    elif [ -f "$1" ]; then
        if [[ $1 == */* ]]; then
            echo "$(cd "${1%/*}"; pwd)/${1##*/}"
        else
            echo "$(pwd)/$1"
        fi
    elif [ -d $(dirname "$1") ]; then
            echo "$(cd $(dirname "$1"); pwd)/$(basename "$1")"
    fi
}

function joinAndReplace() {
    INPUT="$1"
    OUTPUT="$2"
    MAPPING="$3"
    FIELDS="$4"

    LC_ALL=C join -t $'\t' -o "$FIELDS" <(LC_ALL=C sort -k1,1 "$MAPPING") <(LC_ALL=C sort -k1,1 "$INPUT") | LC_ALL=C sort -k1,1 > "$OUTPUT"
}

function hasCommand () {
    command -v $1 >/dev/null 2>&1 || { echo "Please make sure that $1 is in \$PATH."; exit 1; }
}

hasCommand awk
hasCommand comm
hasCommand join
hasCommand sort

# pre processing
# check number of input variables
[ "$#" -ne 5 ] && echo "Please provide <i:oldDB> <i:newDB> <i:oldDB_clustering> <o:newDB_clustering> <o:tmpDir>" && exit 1;

# check if files exists
[ ! -f "$1" ] &&  echo "$1 not found!" && exit 1;
[ ! -f "$2" ] &&  echo "$2 not found!" && exit 1;
[ ! -f "$3" ] &&  echo "$3 not found!" && exit 1;
[   -f "$4" ] &&  echo "$4 exists already!" && exit 1;
[ ! -d "$5" ] &&  echo "tmp directory $5 not found!" && exit 1;

OLDDB="$(abspath $1)" #"../data/DB"
OLDCLUST="$(abspath $3)" #"DBclustered"
NEWDB="$(abspath $2)" #"../data/targetDB"
TMP="$(abspath $5)" #"tmp/"
NEWCLUST="$(abspath $4)"

notExists "$TMP/removedSeqs" \
    && $MMSEQS diffseqdbs "$OLDDB" "$NEWDB" \
                          "$TMP/removedSeqs" "$TMP/mappingSeqs" "$TMP/newSeqs" ${DIFF_PAR} \
    || fail "Diff died"

if [ ! -s "$TMP/mappingSeqs" ]; then
    echo <<WARN
WARNING: There are no common sequences between $OLDDB and $NEWDB.
If you aim to add the sequences of $NEWDB to your previous clustering $OLDCLUST, you can run:

mmseqs concatdbs \"$OLDDB\" \"$NEWDB\" \"${OLDDB}.withNewSequences\"
mmseqs concatdbs \"${OLDDB}_h\" \"${NEWDB}_h\" \"${OLDDB}.withNewSequences_h\"
mmseqs clusterupdate \"$OLDDB\" \"${OLDDB}.withNewSequences\" \"$OLDCLUST\" \"$NEWCLUST\" \"$TMP\"
WARN
    rm -f "$TMP/removedSeqs"  "$TMP/mappingSeqs" "$TMP/newSeqs"
    exit 1
fi

if [ -n "$PRESERVE_REPR" ] && [ -f "$TMP/removedSeqs" ]; then
    echo "==================================================="
    echo "========= Recover removed representatives ========="
    echo "==================================================="

    notExists "$TMP/OLDCLUST.allRepr" && ( \
            $MMSEQS result2stats "$OLDDB" "$OLDDB" "$OLDCLUST" "$TMP/OLDCLUST.allRepr" --stat firstline; \
            rm "$TMP/OLDCLUST.allRepr.index"; \
            tr -d '\000' < "$TMP/OLDCLUST.allRepr" > "$TMP/OLDCLUST.allReprNN"; \
            mv -f "$TMP/OLDCLUST.allReprNN" "$TMP/OLDCLUST.allRepr" \
        ) || fail "result2stats died"

    LC_ALL=C comm -12 <(LC_ALL=C sort "$TMP/removedSeqs") <(LC_ALL=C sort "$TMP/OLDCLUST.allRepr") > "$TMP/OLDCLUST.removedRepr"
    if [[ -f "$TMP/OLDCLUST.removedRepr" ]]; then
        notExists "$TMP/OLDCLUST.removedReprSeqs" \
            && $MMSEQS createsubdb "$TMP/OLDCLUST.removedRepr" "$OLDDB" "$TMP/OLDDB.removedReprSeqs" \
            || fail "createsubdb died"

        notExists "$TMP/OLDCLUST.removedReprMapping" && ( \
                HIGHESTID="$(sort -r -n -k1,1 "${NEWDB}.index"| head -n 1 | cut -f1)"; \
                awk -v highest="$HIGHESTID" \
                    'BEGIN { start=highest+1 } { print $1"\t"highest; highest=highest+1; }' \
                    "$TMP/OLDCLUST.removedRepr" > "$TMP/OLDCLUST.removedReprMapping"; \
                cat "$TMP/OLDCLUST.removedReprMapping" >> "$TMP/mappingSeqs"; \
            ) || fail "Could not create $TMP/OLDCLUST.removedReprMapping"

        notExists "$TMP/NEWDB.withOldRepr" && ( \
                ln -sf "$OLDDB" "$TMP/OLDDB.removedReprDb"; \
                joinAndReplace "${OLDDB}.index" "$TMP/OLDDB.removedReprDb.index" "$TMP/OLDCLUST.removedReprMapping" "1.2 2.2 2.3"; \
                joinAndReplace "${OLDDB}.lookup" "$TMP/OLDDB.removedReprDb.lookup" "$TMP/OLDCLUST.removedReprMapping" "1.2 2.2"; \
                $MMSEQS concatdbs "$NEWDB" "$TMP/OLDDB.removedReprDb" "$TMP/NEWDB.withOldRepr" --preserve-keys; \
                ln -sf "${NEWDB}_h" "$TMP/NEWDB.withOldRepr_h"; \
                ln -sf "${NEWDB}_h.index" "$TMP/NEWDB.withOldRepr_h.index"; \
                cat "${NEWDB}.lookup" "$TMP/OLDDB.removedReprDb.lookup" > "$TMP/NEWDB.withOldRepr.lookup"; \
                NEWDB="$TMP/NEWDB.withOldRepr"; \
            ) || fail "Could not create $TMP/NEWDB.withOldRepr"

        if [ -n "$REMOVE_TMP" ]; then
            echo "Remove temporary files 1/3"
            rm -f "$TMP/OLDCLUST."{allRepr,removedRepr,removedReprMapping} \
                "$TMP/OLDDB."{removedReprDb,removedReprDb.index,removedReprDb.lookup,removedReprSeqs,removedReprSeqs.index}
        fi
    fi
fi

#read -n1
echo "==================================================="
echo "=== Update the new sequences with the old keys ===="
echo "==================================================="

notExists "$TMP/newMappingSeqs" && ( \
        OLDHIGHESTID="$(sort -r -n -k1,1 "${OLDDB}.index"| head -n 1 | cut -f1)"; \
        NEWHIGHESTID="$(sort -r -n -k1,1 "${NEWDB}.index"| head -n 1 | cut -f1)"; \
        MAXID="$(($OLDHIGHESTID>$NEWHIGHESTID?$OLDHIGHESTID:$NEWHIGHESTID))"; \
        awk -v highest="$MAXID" \
            'BEGIN { start=highest+1 } { print $1"\t"highest; highest=highest+1; }' \
            "$TMP/newSeqs" > "$TMP/newSeqs.mapped"; \
        awk '{ print $2"\t"$1 }' "$TMP/mappingSeqs" > "$TMP/mappingSeqs.reverse"; \
        cat "$TMP/mappingSeqs.reverse" "$TMP/newSeqs.mapped" > "$TMP/newMappingSeqs"; \
        awk '{ print $2 }' "$TMP/newSeqs.mapped" > "$TMP/newSeqs"; \
    ) || fail "Could not create $TMP/newMappingSeqs"


notExists "$TMP/NEWDB.index" \
    && joinAndReplace "${NEWDB}.index" "$TMP/NEWDB.index" "$TMP/newMappingSeqs" "1.2 2.2 2.3" \
    || fail "join died"


notExists "$TMP/NEWDB_h.index" \
    && joinAndReplace "${NEWDB}_h.index" "$TMP/NEWDB_h.index" "$TMP/newMappingSeqs" "1.2 2.2 2.3" \
    || fail "join died"


notExists "$TMP/NEWDB.lookup" \
    && joinAndReplace "${NEWDB}.lookup" "$TMP/NEWDB.lookup" "$TMP/newMappingSeqs" "1.2 2.2" \
    || fail "join died"

ln -s "${NEWDB}" "$TMP/NEWDB"
ln -s "${NEWDB}_h" "$TMP/NEWDB_h"
NEWDB="$TMP/NEWDB"

if [ -n "$REMOVE_TMP" ]; then
    echo "Remove temporary files 2/3"
    rm -f "$TMP/NEWDB.withOldRepr"{,.index,.lookup,_h,_h.index}
fi

#read -n1

echo "==================================================="
echo "====== Filter out the new from old sequences ======"
echo "==================================================="
notExists "$TMP/NEWDB.newSeqs" \
    && $MMSEQS createsubdb "$TMP/newSeqs" "$NEWDB" "$TMP/NEWDB.newSeqs" \
    || fail "Order died"

#read -n1
echo "==================================================="
echo "======= Extract representative sequences =========="
echo "==================================================="
notExists "$TMP/OLDDB.mapped.repSeq" \
    && $MMSEQS result2msa "$OLDDB" "$OLDDB" "$OLDCLUST" "$TMP/OLDDB.repSeq" --only-rep-seq \
    || fail "Result2msa died"

#read -n1
echo "==================================================="
echo "======== Search the new sequences against ========="
echo "========= previous (rep seq of) clusters =========="
echo "==================================================="
mkdir -p "$TMP/search"
notExists "$TMP/newSeqsHits" \
    && $RUNNER $MMSEQS search "$TMP/NEWDB.newSeqs" "$TMP/OLDDB.repSeq" "$TMP/newSeqsHits" "$TMP/search" --max-seqs 1 ${SEARCH_PAR} \
    || fail "Search died"

notExists "$TMP/newSeqsHits.swapped.all" \
    && $MMSEQS swapresults "$TMP/NEWDB.newSeqs" "$TMP/OLDDB.repSeq" "$TMP/newSeqsHits" "$TMP/newSeqsHits.swapped.all" \
    || fail "Swapresults died"

notExists "$TMP/newSeqsHits.swapped" \
    && $MMSEQS filterdb "$TMP/newSeqsHits.swapped.all" "$TMP/newSeqsHits.swapped" --trim-to-one-column \
    || fail "Trimming died"

#read -n1
echo "==================================================="
echo "=  Merge found sequences with previous clustering ="
echo "==================================================="
if [ -f "$TMP/newSeqsHits.swapped" ]; then
    notExists "$TMP/updatedClust" \
        && $MMSEQS mergedbs "$OLDCLUST" "$TMP/updatedClust" "$TMP/newSeqsHits.swapped" "$OLDCLUST" \
        || fail "Mergeffindex died"
else
    notExists "$TMP/updatedClust" \
        && ln -s "$OLDCLUST" "$TMP/updatedClust" \
        || fail "Mv Oldclust to update died"

    notExists "$TMP/updatedClust.index" \
        && ln -s "$OLDCLUST.index" "$TMP/updatedClust.index" \
        || fail "Mv Oldclust to update died"
fi

#read -n1
echo "==================================================="
echo "=========== Extract unmapped sequences ============"
echo "==================================================="
notExists "$TMP/noHitSeqList" \
    && awk '$3==1 {print $1}' "$TMP/newSeqsHits.index" > "$TMP/noHitSeqList"

notExists "$TMP/toBeClusteredSeparately" \
    && $MMSEQS createsubdb "$TMP/noHitSeqList" "$NEWDB" "$TMP/toBeClusteredSeparately" \
    || fail "Order of no hit seq. died"

#read -n1
echo "==================================================="
echo "===== Cluster separately the alone sequences ======"
echo "==================================================="

mkdir -p "$TMP/cluster"
notExists "$TMP/newClusters" \
    && $MMSEQS cluster "$TMP/toBeClusteredSeparately" "$TMP/newClusters" "$TMP/cluster" ${CLUST_PAR} \
    || fail "Clustering of new seq. died"

#read -n1
echo "==================================================="
echo "==== Merge the updated clustering together with ==="
echo "=====         the new clusters               ======"
echo "==================================================="
if [ -f "$TMP/newClusters" ]; then
    notExists "$NEWCLUST" \
        && $MMSEQS concatdbs "$TMP/updatedClust" "$TMP/newClusters" "$NEWCLUST" \
        || fail "Dbconcat died"
else
    notExists "$NEWCLUST" \
        && mv "$TMP/updatedClust" "$NEWCLUST" \
        || fail "Mv died"

    notExists "${NEWCLUST}.index" \
        && mv "$TMP/updatedClust.index" "${NEWCLUST}.index" \
        || fail "Mv died"
fi

#read -n1
if [ -n "$REMOVE_TMP" ]; then
    echo "Remove temporary files 3/3"
    rm -f "$TMP/newSeqs.mapped" "$TMP/mappingSeqs.reverse" "$TMP/newMappingSeqs"

	rm -f "$TMP/newClusters" "$TMP/newClusters.index" \
	      "$TMP/toBeClusteredSeparately" "$TMP/toBeClusteredSeparately.index" \
	      "$TMP/noHitSeqList" "$TMP/newSeqsHits.index" "$TMP/newSeqsHits" \
	      "$TMP/newSeqsHits.swapped" "$TMP/newSeqsHits.swapped.index"

	rm -f "$TMP/newSeqsHits.swapped.all" "$TMP/newSeqsHits.swapped.all.index" \
	      "$TMP/NEWDB.newSeqs" "$TMP/NEWDB.newSeqs.index" \
	      "$TMP/OLDCLUST.mapped" "$TMP/OLDCLUST.mapped.index" \
	      "$TMP/mappingSeqs" "$TMP/newSeqs" "$TMP/removedSeqs"

	rm -f "$TMP/OLDDB.repSeq" "$TMP/OLDDB.repSeq.index" \
	      "$TMP/updatedClust" "$TMP/updatedClust.index"

    rm -f "$TMP/update_clustering.sh"

	rmdir "$TMP/search" "$TMP/cluster"
fi
