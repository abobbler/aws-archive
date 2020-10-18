# AWS Archival

Random scripts to watch a directory and upload its contents to AWS glacier, keeping an index of what's been uploaded.


* glacier-archive.sh: The script that multi-part-uploads files to glaciar and maintains the index
* glacier-retrieve.sh: A script to watch a retrieval directory for a retrieval request; it will then download the data, decrypt, and make it available
* treehash.sh: The AWS-256 Tree Hash algorithm, in bash. O(ln(n)) complexity -- lower than their Java example, but maybe higher overall memory usage because hashes are stored as strings. (But maybe lower overall, because Bash vs Java.)
