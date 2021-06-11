file_name=$(ls *.rockspec)

prefix='kong-scalable-rate-limiter'
suffix='-1.rockspec'

version=${file_name#"$prefix"}
version=${version%"$suffix"}

new_version=$1
new_version=${new_version#"v"}

sed -i.bak "s/$version/$new_version/g" $file_name && rm *.bak

new_file_name="$prefix$new_version$suffix"

git config user.name github-actions
git config user.email github-actions@github.com

git mv $file_name $new_file_name
git add .
git commit -m "chore: bump version from $version to $new_version"
git push
