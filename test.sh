file_name=$(ls *.rockspec)

prefix='kong-scalable-rate-limiter-'
suffix='-1.rockspec'

version=${file_name#"$prefix"}
version=${version%"$suffix"}

new_version=$1
new_version=${new_version#"v"}

echo $version
echo $new_version
