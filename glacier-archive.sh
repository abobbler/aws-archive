#!/bin/bash

###########################################
# Amazon AWS Glacier Archive Service
###########################################
#
# This script is intended to upload old archives, such as user directories,
# to Amazon Glacier. At time of writing, cost is 1.15c/GB, which amounts to
# 11.50/TB per month, or 120$/TB per year. That's less than I can manage a
# USB disk for. So, on with Glacier!
#
# This glacier upload script will handle all of the uploading to the archive
# vault. It will read from the ReadyNAS cold_archive share, and upload data
# from there to Amazon Glacier. It will keep a record of the upload, and
# delete the archive after 60 days.
#
# The goal with cold storage is to keep the data for six years, unless it's
# deleted first. It might be deleted first if, for example, ratchet data
# relating to a disassembled robot is cleared out. That seems unlikely, but
# whatever.
#
# Policy for old user directories:
# - Chuck says, 'We should stash them somewhere off of spinning disk.'

#
# Index.txt format:
# <filename> \t <id/loc> \t ####(upl time:date +%s) \t xxxx(md5)
# That is, each field is separated by a tab, and the fields are:
# <filename>: the filesystem filename
# <id/loc>: The Amazon Glacier location field. The ID is the final part of this relative URI.
# #### upl time: the time this file was uploaded, as output by `date +%s`.
#	(used for determining file age -- should it be deleted now??)
# xxxx md5: the MD5 hash of the file. This, so we can be sure that if a
#	filename reappears, we know it's a different file or not.
#
# For reference, data retrieval cost is 5c per 1000 requests + 1c per gig.
# See: http://aws.amazon.com/glacier/faqs/ #Billing, paragraph 2. Somewhere I saw that you
# can retrieve up to 20% of your monthly storage quota for free.


# Note that credentials are stored in ~/.aws
# Note also that account-id - (with the -) causes credentials to be used from config.
MAX_AGE_DAYS=120			# Age since upload when we delete files.

VERBOSITY=0
# The number of MB to upload in one multipart upload block (def 2048 MB)
UPLOAD_BLOCK_SIZE=$(( 2 << 10 ))
COLD_ARCHIVE_LOCATION=/mnt/cold_archive

UPLOADLOG="$COLD_ARCHIVE_LOCATION/uploadlog.txt"

if ! [ -f "$COLD_ARCHIVE_LOCATION/index.txt" ]; then
	echo "cold_archive appears to not be mounted."
	exit 1
fi

# Nope..
while [ "${COLD_ARCHIVE_LOCATION:$((${#COLD_ARCHIVE_LOCATION}-1))}" = '/' ]; do
	COLD_ARCHIVE_LOCATION="${COLD_ARCHIVE_LOCATION%/}"
done

# Only one Glacier upload script should run at a time.
pidfile=/run/glacier-archive.pid
if [ -f "$pidfile" ] && kill -0 `cat $pidfile` 2>/dev/null; then
	echo "Only one glacier-archive can run at a time."
	exit 1
fi
echo $$ > "$pidfile"

# At least five days, guys.
if [ $MAX_AGE_DAYS -lt 5 ]; then
	MAX_AGE_DAYS=5
fi

# Is the upload log excessive in size?
if [ -f "$UPLOADLOG" ] && [ `stat -c %s ""$UPLOADLOG""` -gt $(( 1 << 36)) ]; then
	# Increment numbering
	# How many do we have currently?
	i=0
	while [ -f "$COLD_ARCHIVE_LOCATION/uploadlog.$i.xz" ]; do
		(( i++ ))
	done

	# Rename existing log files
	while [ $i -gt 0 ]; do
		(( i-- ))
		mv "$COLD_ARCHIVE_LOCATION/uploadlog.$i.xz" "$COLD_ARCHIVE_LOCATION/uploadlog.$(( $i + 1 )).xz"
	done

	xz -9 < "$UPLOADLOG" > "$COLD_ARCHIVE_LOCATION/uploadlog.0.xz"
fi

TODAY=$(( $(date +%s) / 86400))

main() {
    # We backgrounded, so update with new PID..
    echo $$ > "$pidfile"
	for f in "$COLD_ARCHIVE_LOCATION/"*; do

		# Skip text files. I want to do only txz, but..
		fname="${f##*/}"
		[ "${fname##*.}" = txt ] && continue
		[ "${fname:0:4}" = "tmp." ] && continue
		[ "${fname##*.}" = sh ] && continue
		[ "${fname##*.}" = log ] && continue
		[ -d "$f" ] && continue		# Skip directories
		[ -r "$f" ] || continue		# Can't read, no upload
		[ -s "$f" ] || continue		# No empty files.

		# Exclude known filenames
		[ "$fname" = index.txt ] && continue
		[ "$f" = "$UPLOADLOG" ] && continue
		[ "$fname" = "$UPLOADLOG" ] && continue

		#fmd5=$(md5sum "$f" | cut -b1-32)
		fsize=$(stat -c %s "$f")
		ftime=$(stat -c %Y "$f")

		# Has this archive been handled (successfully) before?
		fupl=0
        fuplhash=''
		while read -r lin; do
			# If the line matches the filename, tab, then it's been uploaded.
			#echo "test: \"${fname}	\" = \"${lin:0:$((${#fname} + 1))}\""
			if [ "${fname}	" = "${lin:0:$((${#fname} + 1))}" ]; then
				# Uploaded is time when it was uploaded. Last field is md5, second to
				# last is upload time.
                fuplhash="${lin##*	}"
                fuplhash="${fuplhash%-*}" # hsh="${hsh:0:32}" -- equivalent
				lin="${lin%	*}"
				fupl="${lin##*	}"


				[ $fupl -gt 0 ] && break
			fi
		done < <(grep "	[0-9]\+	.*	$ftime-[-0-9]*	[0-9]\+	[a-f0-9]\{32\}\(-[0-9a-f]\{32\}\)\?$" "$COLD_ARCHIVE_LOCATION/index.txt") #<(grep "$fmd5\$" "$COLD_ARCHIVE_LOCATION/index.txt")

		# If the file's been handled, check to see if it's time to purge it.
		if [ $fupl -gt 0 ]; then
			# Remember, delete things after a while.
			fage=$(( $TODAY - $fupl / 86400))
			if [ $fage -gt $(( $MAX_AGE_DAYS + 5 )) ]; then
				# Is the script not running? what's up? why are files not getting deleted?
				# Maybe a file with matching MD5 and name was recopied here, maybe ...
				echo "Error: $f: Age detected as $fage, which is considerably greater than the maximum of $MAX_AGE_DAYS..."
			fi
            if [ $MAX_AGE_DAYS -lt $(( $TODAY - $fupl / 86400)) ]; then
                # Check the hash
                fhash="$(md5sum "$f" | cut -b1-32)"
                if [ "$fhash" = "$fuplhash" ]; then
    				echo "File $f has aged out."
    				rm "$f"
                else
                    # This isn't an error; this is a different file.
                    # Probably the file became corrupt somehow, since it has the same mod time.
                    echo "Error: \`$f': File is aged out but hash doesn't match."
                fi
			fi
			# else, wait it out.
			
			continue
		fi

		# Skip if too big.
		if [ `df . | tail -n1 | awk '{print $4}'` -lt $(( ($fsize >> 10) + 100 )) ] ||
				[ $fsize -lt $(( 1 << 31 )) ] &&
				[ $fsize -lt $(( $UPLOAD_BLOCK_SIZE << 1 )) ] &&
				[ `df . | tail -n1 | awk '{print $4}'` -lt \
					 $(( ($fsize >> 10) + 100 + ( $UPLOAD_BLOCK_SIZE << 1 ) )) ]; then
			echo "$fname: Need free space at least the size of the file + 100KB." >> $UPLOADLOG
			continue
		fi

		errorfile="$(mktemp)"

		# New file. Ok. Upload it, index it.
		echo '======================='
		date
		echo "Uploading: $f"

		# Store permissions for restoration.
		fperm="$(stat -c %u-%g-%a "$f")"
		fcrypted="$COLD_ARCHIVE_LOCATION/crypted/$fname.gpg"

		output="$(gpg --no-tty --no-use-agent --passphrase-file /etc/archive-passphrase -o "$fcrypted" --symmetric "$f" 2>&1)"
		ret=$?
		if [ $ret -ne 0 ]; then
			echo
			echo "Error: Unable to encrypt archive file \"$fname\":"
			echo "================================================="
			echo "$output"
			echo "Return: $ret"
			echo "================================================="
		fi >> "$UPLOADLOG"

		# Encryption changes the file size.
		fsize=`stat -c %s "$fcrypted"`
		if [ $fsize -lt $(( 1 << 31 )) ] && [ $fsize -lt $(( $UPLOAD_BLOCK_SIZE << 1 )) ] ; then
			# 4GB archives can be uploaded in one chunk.
			[ $VERBOSITY -gt 2 ] && echo aws glacier upload-archive --vault-name RethinkArchive --account-id - --archive-description "${f##*/}" --body "$fcrypted"
			response="$(aws glacier upload-archive --vault-name RethinkArchive --account-id - --archive-description "${f##*/}" --body "$fcrypted" 2>"$errorfile")"
			ret=$?

			loc="$(grep '"location"' <<< "$response" | cut -d\" -f4)"
		else
			# Archives > 4GB will be uploaded in 2GB chunks.
			totalresponse=''

			# Initialize to get the upload ID.
			[ $VERBOSITY -gt 2 ] && echo aws glacier initiate-multipart-upload --vault-name RethinkArchive --account-id - --archive-description "${f##*/}" --part-size $(( 1 << 31))
			id="$(aws glacier initiate-multipart-upload --vault-name RethinkArchive --account-id - --archive-description "${f##*/}" --part-size $(( 1 << 31)) 2>"$errorfile")"
			ret=$?
			if [ -s "$errorfile" ]; then
				echo "Errors:"
				cat "$errorfile"
				echo "==========="
			fi
			if [ -z "$id" ]; then
				echo "Received no text for upload id (ret: $ret); bailing on this file."
				echo "==========="

				rm "$fcrypted"
				continue
			fi
			if [ $ret -ne 0 ]; then
				echo "Return value $ret; errors encountered; aborting."
				echo "==========="

				rm "$fcrypted"
				continue
			fi

			# The location piece has the upload id.
			loc="$(grep '"location"' <<< "$id" | cut -d\" -f4)"
			if [ $ret -ne 0 ] || [ -z "$id" ] || [ -z "$loc" ]; then
				echo -n "Multipart initialization failure: "
				date
				echo "$id"

				rm "$fcrypted"
				continue
			fi
			[ $VERBOSITY -gt 0 ] && echo "initiate-multipart-upload response: $id"
			id="${loc##*/}"

			# Use this for each part. 
			i=0
			len=$fsize
			while [ $(( i * ($UPLOAD_BLOCK_SIZE << 20) )) -lt $len ]; do
				tmpname="$(mktemp --tmpdir="$COLD_ARCHIVE_LOCATION/crypted/")"

				# chunk end is the range end for this chunk. It'll be start + 2GB
				# unless it's the last chunk in this file.
				chunkend=$(( (i + 1) * (1 << 31) - 1))
				[ $chunkend -ge $len ] && chunkend=$(( len - 1 ))
				
				dd if="$fcrypted" of="$tmpname" bs=$(( 1 << 20)) count=$UPLOAD_BLOCK_SIZE skip=$(( i * ($UPLOAD_BLOCK_SIZE) )) 2>/dev/null
				ret=$?
				[ $ret -eq 0 ] || { rm "$tmpname" "$errorfile" 2>/dev/null; echo "Multipart upload dd failed."; break; }
				
				[ $VERBOSITY -gt 2 ] && echo "Chunk size: $(( $chunkend - (i * (1 << 31)) ))"
				[ $VERBOSITY -gt 2 ] && echo aws glacier upload-multipart-part --vault-name RethinkArchive --account-id - --upload-id="$id" --body "$tmpname" --range "bytes $(( (i << 20) * $UPLOAD_BLOCK_SIZE ))-$chunkend/$len"
				response="$(aws glacier upload-multipart-part --vault-name RethinkArchive --account-id - --upload-id="$id" --body "$tmpname" --range "bytes $(( (i << 20) * $UPLOAD_BLOCK_SIZE ))-$chunkend/$len" 2>"$errorfile")"
				ret=$?
				rm "$tmpname"
				
				if [ -s "$errorfile" ]; then
					echo "Errors:"
					cat "$errorfile"
					echo "==========="
					break
				fi

				unset tmpname

				[ $ret -eq 0 ] || { echo "Multipart upload error response: $response"; break; }

				[ $VERBOSITY -gt 0 ] && echo "Multipart response:"
				[ $VERBOSITY -gt 0 ] && echo "$response"
				(( i++ ))
			done

			# If we failed to upload, loc and/or id should be unset.
			if [ $ret -ne 0 ] || [ -z "$id" ] || [ -z "$loc" ]; then
				# Failure.
				echo "Failure detected. Aborting upload. id $id"
				[ -n "$id" ] && 
					[ $VERBOSITY -gt 2 ] && echo aws glacier abort-multipart-upload --account-id - --vault-name RethinkArchive --upload-id="$id"
				aws glacier abort-multipart-upload --account-id - --vault-name RethinkArchive --upload-id="$id"

				rm "$fcrypted"
				continue
			fi

			fhash="$(/root/bin/treehash.sh "$fcrypted" )"
			[ $VERBOSITY -gt 2 ] && echo aws glacier complete-multipart-upload --account-id - --vault-name RethinkArchive --upload-id="$id" --archive-size $fsize --checksum "$fhash"
			echo "Complete multipart upload:"

            # Grab the output so that we can grab the archive ID from the result.
            output="$(aws glacier complete-multipart-upload --account-id - --vault-name RethinkArchive --upload-id="$id" --archive-size $fsize --checksum "$fhash" 2>"$errorfile")"
			ret=$?

            # Loc is now the archive id.
            loc="$(grep '"archiveId":' <<< "$output" | sed 's/[^:]\+://; s/[^"]*"//; s/".*//')"

		fi
		echo "$response"

		if [ -f "$errorfile" ] && [ -s "$errorfile" ]; then
			echo 
			echo 'Errors:'
			cat "$errorfile"
			echo '=============='
		fi
		[ -f "$errorfile" ] && rm "$errorfile"
		unset errorfile


		# Finally, only if we didn't encounter an error, record the file in the index.
		if [ $ret -eq 0 ] && [ -n "$loc" ]; then
			# upload success. Index it, mark it uploaded.
			# The "location" property has the ID in it, so just store the one.
            # First, for the upload log.
			echo "${fname}	$fsize	$loc	$ftime-$fperm	$(date +%s)	$(md5sum "$f" | cut -b1-32)-$(md5sum "$fcrypted" | cut -b1-32)"
			echo "${fname}	$fsize	$loc	$ftime-$fperm	$(date +%s)	$(md5sum "$f" | cut -b1-32)-$(md5sum "$fcrypted" | cut -b1-32)" >> "$COLD_ARCHIVE_LOCATION/index.txt"
			cp "$COLD_ARCHIVE_LOCATION/index.txt" /root/glacier-index.txt
			chmod go-r "$f"
			chown root "$f"
		fi
		
		# Cleanup.
		rm "$fcrypted"

	done >> "$UPLOADLOG" 2>&1

	rm "$pidfile"
}

main &>/dev/null &
