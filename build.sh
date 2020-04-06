#!/bin/bash

version=0.0.0
if [[ $1 ]]; then version=$1; fi

build_dir="/tmp/saprunctrl/${version}/"
mkdir -p ${build_dir}

cp -Rf ./usr ${build_dir}
cp -Rf ./etc ${build_dir}

fpm -s dir -t deb -n saprunctrl -v ${version} -C ${build_dir}  --deb-auto-config-files -p ./build

rm -Rf ${build_dir}
