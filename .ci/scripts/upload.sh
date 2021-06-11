rockspec_file_name=$(ls *.rockspec)
luarocks upload $rockspec_file_name --api-key=$1
