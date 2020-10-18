#!/bin/bash
# Build the tree hash..

# Every even block, merge the last two. Rather, every time the current 1MB block is equal
# to the log base 2

if [ $# -lt 1 ]; then
	echo "Usage: $0 <file>"
	echo
	echo "Computes the Amazon SHA-256 tree hash of the given <file>."
	echo "Per Amazon spec, computes the tree hash of 1MB blbocks."
	exit 1
fi 1>&2

f="$1"
if ! [ -f "$f" ]; then
	echo "ERROR: File not found: \`$f'"
	exit 2
fi


hashtree=()
blocknum=0	# 1-based
blocksize=1	# fixed, 1MB
fblocks=$(( `stat -c %s "$f"` / ( $blocksize << 20 ) ))
# +1 block for remainder
[ $(( $fblocks * ($blocksize << 20) )) -lt `stat -c %s "$f"` ] && (( fblocks++ ))

while [ $blocknum -lt $fblocks ]; do
	hashtree+=(`sha256sum <(dd if="$f" bs=$(($blocksize << 20)) skip=$blocknum count=1 2>/dev/null) | cut -b1-64`)
	(( blocknum++ ))

	# Is the current block number an even? Is the logarithm of this block number an even?
	logstart=$blocknum
	while [ $(( logstart % 2)) -eq 0 ] && [ $logstart -gt 0 ]; do
		logstart=$(( logstart >> 1 ))
		b=$(( ${#hashtree[@]} - 1 ))
		a=$(( b - 1 ))

		# Combine the last two tree hashes.
		hashtree[$a]=$(sha256sum <(xxd -r -ps <<< "${hashtree[$a]}${hashtree[$b]}") | cut -b1-64)

		# Delete the last two and add the last one. (Second to last is replaced; delete the last.)
		unset hashtree[$b]
	done
	
	

done

# As there is no more data, collapse the tree.
while [ ${#hashtree[@]} -gt 1 ]; do
	b=$(( ${#hashtree[@]} - 1 ))
	a=$(( b - 1 ))

	# Combine the last two tree hashes.
	hashtree[$a]=$(sha256sum <(xxd -r -ps <<< "${hashtree[$a]}${hashtree[$b]}") | cut -b1-64)

	# Delete the last two and add the last one. (Second to last is replaced; delete the last.)
	unset hashtree[$b]
done

echo "${hashtree[@]}"

