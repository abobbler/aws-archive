#!/bin/bash

# Amazon Glacier Retrieval Server
#
# Because Amazon Glacier uses Peak Rate for billing, while we have a fat pipe,
# we need to slow down retrievals. Only get 2GB/hr (unless requested faster).
# Part of this necessitates filing data requests in a timely (not immediate)
# manner, waiting before retrieving the next part, and so on. Heh.

# Watch the retrieval requests directory for incoming requests
REQUEST_DIR=/mnt/cold_archive/RethinkArchiveRetrieve
INDEX_FILE=/mnt/cold_archive/index.txt
VERBOSITY=4

if [ `whoami` != root ]; then
	echo "Only root may request archives."
	echo "http://aws.amazon.com/glacier/faqs/#How_will_I_be_charged_when_retrieving_large_amounts_of_data_from_Amazon_Glacier"
	echo "The peak rate at which we retrieve data is... as though we've retrieved data at the"
	echo "same rate for the entire month. \"Your peak hourly retrieval rate each month is equal "
	echo "to the greatest amount of data you retrieve in any hour over the course of the month\""
	echo "Apparently all retrievals take 4 hours, so size of archive div 4hr is the retrieval rate."
	echo "3GB/hr * 0.01/GB * 720h = \$21.6  for that 3GB."
	echo "85GB, at 20Mbit. We can download at 2.5MB/sec, or 9GB/hr."
	echo "9GB/hr * 0.01/GB * 720h = \$64.80$. This should be the _maximum_ _monthly_ bill that "
	echo "we'll pay over a 20Mbit link."
	echo "The drawback to this script is that there's no rate-limit. "
	echo "You must pass a \"1\" as the second parameter of this script to acknowledge this fact."
	exit 3
fi


# Only root need apply -- only root has the amazon credentials set up.
if [ `whoami` != root ]; then
	echo "Only root may run this script (only root has credentials configured)"
	exit 1
fi

if ! [ -w "$REQUEST_DIR" ]; then
	echo "ERROR: Unable to write data to archive retrieval directory $REQUEST_DIR"
	exit 2
fi

# Are we already running as a server?
if [ -f /run/"${0##*/}".pid ]; then
	kill -0 "$(cat /run/"${0##*/}".pid)" 2>/dev/null && exit 2
fi

echo $$ > /run/"${0##*/}".pid

REQUEST_DIR="${REQUEST_DIR%/}"

# Lately, I've been having download issues.
BLOCKSIZE_GIGS=2

# Keep track of how many parts (hours) we need to run. This increases as
# additional requests come in.
partsleft=0

# Current day retrieval rate. Suppose a request asks for 5GB/hr retrieval. Ok,
# cool. But that 5GB/hr is the peak rate for the _month_ now, so we may as well
# use it for the remainder of the month.
curmonum=`date +%m`
curmonum=${curmonum#0}
datarateappliedsleep=0

# Default retrieval rate for the month: 2GB/hr.
response="$(aws glacier set-data-retrieval-policy --account-id - --cli-input-json '{ "Policy": { "Rules": [ { "BytesPerHour": '$(( 2 << 30))', "Strategy": "BytesPerHour" } ] } }')"

# $1: filename
# $2: Archive ID
# $3: block number (0-based)
# $4: Total file size
# $5: the log file
# Returns:
#  0: nothing special; either the start block doesn't apply, or it's processing.
#  1: block fully retrieved
#  2: error
startblock() {
	local fname block fsize archid awaitingfile
	local response havearchid retval

	fname="$1"
	archid="$2"
	block="$3"
	fsize="$4"
	awaitingfile="$5"

	# Default, no-info return.
	retval=0
	if [ $VERBOSITY -ge 3 ]; then
		echo "startblock:"
		echo fname="$1"
		echo archid="$2"
		echo block="$3"
		echo fsize="$4"
		echo awaitingfile="$5"
		echo
	fi

	# Split it into 4GB chunks. Retrieval takes 4 hours, and I can reasonably download
	# 8GB chunks in 4 hours before the next retrieval can start.
	endsize=$(( ($block + 1) * ($BLOCKSIZE_GIGS << 30) - 1))
	[ $endsize -ge $fsize ] && endsize=$(( $fsize - 1))

	if [ $(( $block * ($BLOCKSIZE_GIGS << 30) )) -gt $endsize ]; then
		[ $VERBOSITY -ge 3 ] && echo "Requested block start beyond end of file."
		return 0
	fi

	# Check to see if this is already gotten.
	aws glacier list-jobs --account-id - --vault-name RethinkArchive |
		grep "\"RetrievalByteRange\":.*\<$(( $block * ($BLOCKSIZE_GIGS << 30) ))-$endsize\>" -A 15 |
		grep -F "$archiveid" > /dev/null
	havearchid=$?

	if [ $havearchid -ne 0 ]; then
		# Retval 0: nothing special, not retrieved.
		retval=0

		# We don't have it. Start the retrieve..
		response="$(aws glacier initiate-job --account-id - --vault-name RethinkArchive --job-parameters "$(
				cat - << EOF
					{
						"Type": "archive-retrieval",
						"ArchiveId": "$archid",
						"RetrievalByteRange": "$(( $block * ($BLOCKSIZE_GIGS << 30) ))-$endsize",
						"Description": "Rethink Cold Archive Retrieval"
					}
EOF
				)")"
		if [ $VERBOSITY -ge 3 ]; then
			echo "initiate-job json:"
			echo '{'$'\n'$'\t'"Type": "archive-retrieval",'$'\n'$'\t'"ArchiveId": "$archiveid",'$'\n'$'\t'"RetrievalByteRange": "$(( $block * ($BLOCKSIZE_GIGS << 30) ))-$endsize",'$'\n'$'\t'"Description": "Rethink Cold Archive Retrieval"'$'\n''}'
		fi
	else
		response="We already have this section of the archive in the jobs-list:"
		response="$response"$'\n'"$(aws glacier list-jobs --account-id - --vault-name RethinkArchive |
			grep -B8 "\"RetrievalByteRange\":.*\<$(( $block * ($BLOCKSIZE_GIGS << 30) ))-$endsize\>" -A 15 |
			grep -A100 '^[[:space:]]*{' | grep --max-count=1 -B100 '^[[:space:]]*}')"

		# Is it complete?
		if grep '"Completed": true' <<< "$response" > /dev/null; then
			retval=1
		fi
	fi # do we already have this job processing?

	{
		date
		echo "StartBlock $block response:"
		echo "$response"
		echo
	} | tee >(cat - >> "$awaitingfile")

	return $retval
}

# Handle the logic of getting a file.
# $1: filename
# $2: archive id
# $3: file size
# all are required, all should be available in index.txt.
getFile() {
	local fname fsize ftime block endsize archiveid secondsstart ret

	local jobid awaitingfile response outputfile filehash result havearchid
	local fperm ftime gid uid retval

	fname="$1"
	archiveid="$2"
	fsize="$3"
	if [ $VERBOSITY -ge 3 ]; then
		echo "getFile:"
		echo fname="$1"
		echo archiveid="$2"
		echo fsize="$3"
		echo
	fi

	secondsstart=$SECONDS

	awaitingfile="$REQUEST_DIR/${fname%.*}-AwaitingData.${fname##*.}"
	[ -f "$REQUEST_DIR/$fname.request" ] && mv "$REQUEST_DIR/$fname.request" "$awaitingfile" || touch "$awaitingfile"

	{
		echo '======================================='
		date
		echo "Initiate archive retrieval job."
		echo "Getting $fname ($archiveid)..."
	} | tee >(cat - >> "$awaitingfile")

	# Get an archive from Glacier.
	outputfile="$fname.$$"
	block=0
	tries=0
	endsize=0
	# While there's more data to grab.. the second is the max value (size) of the last block.
	while [ $(( ($block * $BLOCKSIZE_GIGS) << 30 )) -le $fsize  ]; do
		[ $VERBOSITY -ge 2 ] && echo "Get file: output $outputfile; block $block; tries $tries; endsize $endsize"

		# Split it into 4GB chunks. Retrieval takes 4 hours, and I can reasonably download
		# 8GB chunks in 4 hours before the next retrieval can start.
		endsize=$(( ($block + 1) * ($BLOCKSIZE_GIGS << 30) - 1))
		[ $endsize -ge $fsize ] && endsize=$(( $fsize - 1))

		startblock "$fname" "$archiveid" $block "$fsize" "$awaitingfile"
		retval=$?

		# If we're currently retrieving this block, then just wait.
		if [ $retval -eq 0 ]; then
			sleep 60
			continue
		elif [ $retval -eq 2 ]; then
			# Error.
			tries=$(( $tries + 1))
			[ $tries -eq 5 ] && return $retval
			sleep 15
			continue
		fi
		tries=0

		# Ok. Now wait for it to finish. Do this in the background.
		touch "$REQUEST_DIR/${fname%.*}-AwaitingData.${fname##*.}"

		# Look for the current bock in the job list.
		response="$(aws glacier list-jobs --account-id - --vault-name RethinkArchive |
			grep "\"RetrievalByteRange\":.*\<$(( $block * ($BLOCKSIZE_GIGS << 30) ))-$endsize\>" -A 15 -B 15 |
			grep -F "$archiveid" -A15 -B15 | grep -B20 '}' | grep -A 20 '{')" #
		echo "Response: $response"
		echo "grep \"\"RetrievalByteRange\":.*\<\$(( $block * ($BLOCKSIZE_GIGS << 30) ))-$endsize\>\" -A 15 |"
		echo "grep -F \"$archiveid\" -A15 | grep -B20 '}' | grep -A 20 '{' | grep JobId"

		# Refresh the size. If the file is > 2GB this will work; else, the index must be correct.
		fsize="$(grep ArchiveSizeInBytes <<< "$response")"
		fsize="${fsize#*: }"
		fsize="${fsize%,*}"
		jobid="$(grep JobId <<< "$response")"
		jobid="${jobid#*JobId\": \"}"
		jobid="${jobid%\"*}"

		# Debug-check: if jobid isn't set, then perhaps the command failed. All I can do is retry.
		if [ -z "$jobid" ]; then
			((tries++))
			if [ $tries -lt 5 ]; then
				echo "ERROR: Jobid not set after list-jobs / initiate job. (Try: $tries)"
				echo "Restarting loop to list-jobs and get jobID, or reinitialize job."
				continue
			else
				echo "ERROR: On fifth try, jobid couldn't be gotten from list jobs / initiate-job."
				echo "Please review the above output and fix this script."
				echo "Response:"
				echo $response
				echo -n grep JobId \<\<\< "\$response":
				grep JobId <<< "$response"
				return
			fi
		fi

		tries=0
		while [ $tries -lt 5 ] && sleep 500; do
			# Job ids can start with a -, which causes awscli to look at it like a command-line option.
			# To remedy this, we need to use cli-json.
			response="$(aws glacier describe-job --account-id - --vault-name RethinkArchive \
					--cli-input-json "{\"jobId\":\"$jobid\"}" 2>$$.err)"
			if [ $VERBOSITY -gt 2 ]; then
				{
					echo "`date`: describe-job Response:"
					echo "$response" | grep 'RetrievalByteRange\|StatusCode\|JobId\|ArchiveId\|CreationDate\|Completed'
					echo
					if [ -f $$.err ] && [ `stat -c %s $$.err` -gt 5 ]; then
						echo "Error output:"
						cat $$.err
					else
						echo "Error output: (none)"
					fi
					echo
				} | tee >(cat - >> "$awaitingfile")
			fi
			[ -f $$.err ] && rm $$.err

			if [ $VERBOSITY -gt 2 ]; then
				echo -n "file $fname, block $block: \"Completed\":"
				grep "file $fname, block $block: \"Completed\":" <<< "$response"
				echo
			fi

			if ! grep "\"Completed\":" <<< "$response" > /dev/null; then
				echo "Warning: Unable to get job completion status. Waiting 500 seconds and trying again."
				((tries++))
				if [ $tries -eq 5 ]; then
					echo "ERROR: Fifth try; giving up on this file."
					return
				fi

				# If we have more tries, then restart. If we fall through, then it'll break bec no false.
				continue
			fi

			# Either it's completed (break), or it's InProgress, or wtf is going on?
			grep "\"Completed\": false" <<< "$response" > /dev/null || break
			if ! grep "\"StatusCode\": \"InProgress\"" <<< "$response" > /dev/null; then
				echo "Job for $fname failed. Status Code is not in progress, and the job is not completed."
				echo "$response"
				echo

				echo >> "$awaitingfile"
				echo "Job for $fname failed. Status Code is not in progress, and the job is not completed." >> "$awaitingfile"

				mv "$awaitingfile" "$REQUEST_DIR/${fname%.*}-failed.${fname##*.}"
				return
			fi
		done # Wait for block to complete

		[ $VERBOSITY -gt 2 ] && echo "`date`: Completed waiting for job to complete. Fetching data.."

		# Start the fetch of another block while we download this block.
		if [ $(( ($block + 1) * $BLOCKSIZE_GIGS )) -gt $fsize ]; then
			startblock "$fname" "$archiveid" $(( block + 1 )) "$fsize" "$awaitingfile"
		fi

		# This is set up to be able to go "backward" or "redo" a failed part if the hash doesn't
		# match for that part. notrunc = overwrite the block in a file. $BLOCKSIZE_GIGS << 14 is "shift 4 to 4GB
		# (4 << 30), and then divide by 65536 ( ( 4 << 30 ) >> 16)". 30 - 16 = 14.
		# the dd portion, since I'm not redoing and not doing out-of-order, is equivalent to
		# cat - >> "$outputfile"
		ret=1
		tries=0
		while [ $ret -ne 0 ] && [ $tries -lt 5 ]; do
			# Job ids can start with a -. Unlink with describe-job, I can use --job-id=-xyz.
			response="$(aws glacier get-job-output --account-id - --vault-name RethinkArchive \
					--job-id="$jobid" 2>$$.err \
				>(dd of="$outputfile" bs=65536 seek=$(( $block * ($BLOCKSIZE_GIGS << 14) )) conv=notrunc 2>/dev/null)
				)"
			ret=$?

			((tries++))
			if [ $ret -ne 0 ]; then
				{
				echo "Error grabbing block (try: $tries):"
				cat $$.err
				} >> "$awaitingfile"

				# Start another try. Delay 2 minutes.
				if [ $tries -lt 5 ]; then
					sleep 120
				else
					echo "ERROR: failed grabbing block, fifth try. Giving up."
					return $ret
				fi
			fi
			[ -f $$.err ] && rm $$.err
		done
		[ $VERBOSITY -gt 3 ] && [ $ret -eq 0 ] && [ $tries -lt 5 ] && echo "Successfully grabbed block $block on try $tries."

		# If I reset the time I can tell how long it's been around.
		#touch -t "`date -d@$ftime +%Y%m%d%H%M%S`" "$REQUEST_DIR/${fname}"

		if [ $tries -ge 5 ]; then
			{
				echo
				echo "Exceeded maximum number of allowed attempts ($tries)."
				echo "Giving up on this fetch/file."
				echo
			} >> "$awaitingfile"
			break
		fi

		{
			date
			echo "Respnose to get-job-output for $fname ($archiveid):"
			echo "$response"
			echo
		} >> "$awaitingfile"

		# Next block, next time..
		(( block++ ))

	done # chunked-retrieval

	[ $VERBOSITY -ge 3 ] && echo "Grabbed all chunks."
	# Give the user access permissions
	ftime="${fperm%%-*}"
	fperm="${fperm#*-}"
	uid="${fperm%%-*}"
	gid="${fperm#*-}"
	gid="${gid%-*}"
	fperm="${fperm##*-}"

	mv "$awaitingfile" "$awaitingfile-DEBUG"
	#rm "$awaitingfile"
	output="$(gpg --no-tty --no-use-agent --passphrase-file /etc/archive-passphrase -o "$REQUEST_DIR/$fname" --decrypt "$outputfile" 2>&1)"
	ret=$?

	if [ $ret -ne 0 ]; then
		echo
		echo "$fname: File retrieve failed. ($ret)"
		echo '==============================================='
		echo "$output"
		echo '==============================================='
		mv "$REQUEST_DIR/$fname" "$REQUEST_DIR/$fname-ERROR"
		#rm "$REQUEST_DIR/$fname"
		mv "$outputfile" "$REQUEST_DIR/${fname%.*}-failed.${fname##*.}"
	else
		chown $uid:$gid "$REQUEST_DIR/$fname"
		chmod "0$fperm" "$REQUEST_DIR/$fname"
		touch -t$(date -d@$ftime +'%Y%m%d%H%M%S') "$REQUEST_DIR/$fname"
		echo "Retrieval of $REQUEST_DIR/${fname} complete. Time required: $(( $SECONDS - $secondsstart))"
		rm "$outputfile"
	fi

	[ -f $$.err ] && rm $$.err

	date
	echo "==========================================="
}

while true; do

	glacierpingpid=0
	# Look for the oldest archive in the directory.
	while read -r newrequest; do
		# Request files must end with the word "done"
		doneline=`grep -i --line-number '^done$' "$newrequest" | head -n1 | cut -d: -f1`

		{
			# Rename it, just so that nothing else picks it up again later.
			flock -n 9 || continue
			mv "$newrequest" "$newrequest.$$"
			newrequest="$newrequest.$$"
		} 9<"$newrequest"

		# If no done line, they didn't make a valid request. Requests must end with
		# the single word "done" on the last line of the request.
		if [ -z "$doneline" ]; then
			unset newrequest
			continue
		fi

		# So lets see if the word "done" was on the _last_ line.
		# XXX I dunno why it requires \\$p; possible due to the backtick
		if [ `sed -n "$(($doneline + 1)),\\$p" "$newrequest" | grep '[^[:space:]]' | wc -l` -gt 0 ]; then
			echo "Request ${newrequest:$((${#REQUEST_DIR} + 1))} has invalid format: the word done must be the last line in the file."
			unset newrequest
			continue
		fi

		# Looks like we've got a good request! Lets stop looking for more.
		break
	done < <(
			find "$REQUEST_DIR" -maxdepth 1 -name '*.request' -printf '%T@-%p\n' | sort -rn | sed 's/^[0-9.]\+-//'
		)

	# If we made it this far without a new request, then there is no request (of a valid format).
	# Sleep and wait..
	if [ "x$newrequest" = "x" ]; then
		sleep 60
		continue
	fi

	# So we have a new request.
	[ $VERBOSITY -ge 3 ] && echo "Found new request: $fname"
	fname="${newrequest##*/}"
	fname="${fname%.request.$$}"

	# Does this request have any particulars?
	archiveid="$(grep -i archive-id "$newrequest" | tail -n1 | sed 's/.*[/ :]//; s/[[:space:]].*//')"
	if [ -z "$archiveid" ]; then
		# Get it from the index based on the filename.
		#fname="${newrequest##*/}"
		#fname="${fname%.request}"
		archiveid="$(grep -F "$fname	" "$INDEX_FILE" | grep "^.\{${#fname}\}	" | tail -n1 | cut -d$'\t' -f2,3,4 | sed 's/\t.*\//\t/')"
		fsize="${archiveid%%	*}"
		fperm="${archiveid##	*}"	# Get the last component
		archiveid="${archiveid#*	}"	# Get the center component.
		archiveid="${archiveid%	*}"
	else
		# Use the name of the request file.
		#fname="${newrequest##*/}"
		#fname="${fname%.request}"
		fsize="$(grep -F "/$archiveid	" "$INDEX_FILE" | cut -d$'\t' -f2,4)"
		fperm="${fsize%	*}"	# Get the second component
		fperm="${fperm#*	}"
		fsize="${fsize%	*}"	# Strip the permissions off the size component
	fi

	if [ -z "$archiveid" ]; then
		echo "Archive id not found for: ${newrequest##*/}"
		[ -d "$REQUEST_DIR/error" ] || mkdir "$REQUEST_DIR/error"
		echo "Archive id not found for: ${newrequest##*/}" >> "$newrequest"
		mv "$newrequest" "$REQUEST_DIR/error"
		continue
	fi

	# Rate specifications?
	retrieverate="$(grep -i retrieverate "$newrequest" | sed 's/.*[/ :]//; s/^[[:space:]]\+//; s/[[:space:]]\+$//')"
	if [ -n "$retrieverate" ]; then
		# Not numeric? Not help you.
		if grep '^[0-9]\+$' <<< "$retrieverate" > /dev/null; then
			echo "Invalid retrieval rate ($retrieverate) for: ${newrequest##*/}"
			[ -d "$REQUEST_DIR/error" ] || mkdir "$REQUEST_DIR/error"
			echo "Invalid retrieval rate ($retrieverate) for: ${newrequest##*/}" >> "$newrequest"
			mv "$newrequest" "$REQUEST_DIR/error"
		continue
		fi
	else
		# Will be overridden by the current monthly minimum.
		retrieverate=0
	fi
	retrieveby="$(grep -i retrieveby "$newrequest" | sed 's/.*[/ :]//; s/^[[:space:]]\+//; s/[[:space:]]\+$//')"
	if [ -n "${retrieveby}" ] && [ $retrieverate -eq 0 ]; then
		# Retrieve Rate takes precedence over retrieve by.
		# If we have retrieveby, it's supposed to be a seconds since epoch.

		# Not numeric? Not help you.
		if grep '^[0-9]\+' <<< "$retrieverate" > /dev/null; then
			echo "Invalid retrieby epoch ($retrieveby) for: ${newrequest##*/}"
			[ -d "$REQUEST_DIR/error" ] || mkdir "$REQUEST_DIR/error"
			echo "Invalid retrieby epoch ($retrieveby) for: ${newrequest##*/}" >> "$newrequest"
			mv "$newrequest" "$REQUEST_DIR/error"
		continue
		fi

		# If the epoch is < 1433369966 (time of script writing), then it's eroneous.
		if [ 1433369966 -ge $retrieveby ]; then
			echo "Invalid retrieby epoch ($retrieveby) for: ${newrequest##*/}"
			[ -d "$REQUEST_DIR/error" ] || mkdir "$REQUEST_DIR/error"
			echo "Invalid retrieby epoch ($retrieveby) for: ${newrequest##*/}" >> "$newrequest"
			mv "$newrequest" "$REQUEST_DIR/error"
		fi

		# If it's already elapsed, well.. that's unfortunate.
		# Note that it takes 4hr to retrieve the first piece and suppose an hour to download that.
		if [ $(( $retrieveby - (5 * 3600) )) -gt `date +%s` ]; then
			# Just something to make calculations on the next line succeed.
			retrieveby=$(( `date +%s` + (6 * 3600) ))
		fi

		# Ok. Figure out the rate we need to accomplish this result by that time. How many hours do we
		# have, and how big is it?
		# Note that there is at least four hours (well.. five, with download time) overhead.
		fsize="$(grep -F "$archiveid" "$INDEX_FILE" | cut -d$'\t' -f2)"
		retrieverate=$(( (($fsize >> 20) + 1) / (($retrieveby - `date +%s` / 3600) - 4) ))
		retrieverate=$(( $retrieverate >> 10))

		[ $retrieverate -gt 8 ] && retrieverate=8 ||
		[ $retrieverate -lt 2 ] && retrieverate=2
	fi
	# Settings set for this request.

	# If the retrieve rate is less that 8 (GB/hr), then set it as the retrieve rate.
	if [ $retrieverate -lt 8 ]; then
		# Only if current retrieval rate for the month is less.
		nowmonum=`date +%m`
		if [ $curmonum -ne ${nowmonum#0} ]; then
			aws glacier set-data-retrieval-policy --account-id - --cli-input-json '{ "Policy": { "Rules": [ { "BytesPerHour": '$(( $retrieverate << 30))', "Strategy": "BytesPerHour" } ] } }'
			datarateappliedsleep=1
		else
			# We're not in a new month. Update the rate if it's faster than this month's current rate.
			output="$(aws glacier get-data-retrieval-policy --account-id -)"
			if grep '"Strategy":[[:space:]]*"BytesPerHour"' <<< "$output" > /dev/null; then
                		currate="$(grep '"BytesPerHour":' <<< "$output" | sed 's/.*:[[:space:]]*//; s/,.*//')"
				if [ $currate -lt $(( $retrieverate << 30)) ]; then
					aws glacier set-data-retrieval-policy --account-id - --cli-input-json '{ "Policy": { "Rules": [ { "BytesPerHour": '$(( $retrieverate << 30))', "Strategy": "BytesPerHour" } ] } }'
					datarateappliedsleep=1
				fi
			elif grep '"Strategy":[[:space:]]*"None"' <<< "$output" > /dev/null; then
				# NO limit?!?
				aws glacier set-data-retrieval-policy --account-id - --cli-input-json '{ "Policy": { "Rules": [ { "BytesPerHour": '$(( $retrieverate << 30))', "Strategy": "BytesPerHour" } ] } }'
				datarateappliedsleep=1
			fi
		fi
	fi

	i=0
	while true; do
		# Sleep and repeat as long as necessary to get it so we have the correct data rate.
		if [ $datarateappliedsleep -gt 0 ]; then
			echo "Data rate application leads to sleep. Please hold, ..."
			sleep 500
			datarateappliedsleep=0
		fi

		output="$(aws glacier get-data-retrieval-policy --account-id -)"
		method="$(grep '"Strategy":' <<< "$output" | sed 's/.*:[[:space:]]*"\?//; s/[",].*//')"
		rate="$(grep '"BytesPerHour":' <<< "$output" | sed 's/.*:[[:space:]]*"\?//; s/[",].*//')"


		if [ "$method" != "BytesPerHour" ] && [ "$method" != "FreeTier" ] || [ -n "$rate" ] && [ "$rate" -lt $(( $retrieverate << 30)) ]; then
			echo "Resetting retrieval rate from $method: $rate to $(( $retrieverate << 30)) BytesPerHour."
			aws glacier set-data-retrieval-policy --account-id - --cli-input-json '{ "Policy": { "Rules": [ { "BytesPerHour": '$(( $retrieverate << 30))', "Strategy": "BytesPerHour" } ] } }'

			(( i++ ))
			if [ $i -gt 10 ] && [ $(( $i % 10)) -gt 0 ]; then
				echo "WARNING: Looped $i times trying to set retrieval rate."
			fi

			datarateappliedsleep=1

			continue
		fi

		echo "Retrieval rate set to: $retrrate"
		break
	done

	# file mod time is the fourth field... should I use this?
	#ftime="`cut -f4 <<< "$fname"`"

	# This really, truly does help transfers not time out.
	ping glacier.us-east-1.amazonaws.com &>/dev/null &
	glacierpingpid=$!
	getFile "$fname" "$archiveid" "$fsize"
	echo "File \`$fname' complete (or error?)."
	kill $glacierpingpid &>/dev/null
done >> /mnt/cold_archive/retrievelog.txt

