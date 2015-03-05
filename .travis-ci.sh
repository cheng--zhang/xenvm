## declare required packages

OPAM_PACKAGES="cstruct lwt cohttp ssl ocamlfind shared-block-ring camldm cmdliner bisect mirage-block-volume"

## different PPAs required to cover the test matrix

case "$OCAML_VERSION,$OPAM_VERSION" in
    3.12.1,1.0.0) ppa=avsm/ocaml312+opam10 ;;
    3.12.1,1.1.0) ppa=avsm/ocaml312+opam11 ;;
    4.00.1,1.0.0) ppa=avsm/ocaml40+opam10 ;;
    4.00.1,1.1.0) ppa=avsm/ocaml40+opam11 ;;
    4.01.0,1.0.0) ppa=avsm/ocaml41+opam10 ;;
    4.01.0,1.1.0) ppa=avsm/ocaml41+opam11 ;;
    4.01.0,1.2.0) ppa=avsm/ocaml41+opam12 ;;
    4.02.0,1.2.0) ppa=avsm/ocaml42+opam12 ;;
    *) echo Unknown $OCAML_VERSION,$OPAM_VERSION; exit 1 ;;
esac

## install OCaml and OPAM

echo "yes" | sudo add-apt-repository ppa:$ppa
sudo apt-get update -qq
sudo apt-get install -qq ocaml ocaml-native-compilers camlp4-extra opam
export OPAMYES=1
export OPAMVERBOSE=0
echo OCaml version
ocaml -version
echo OPAM versions
opam --version
opam --git-version

opam init
eval `opam config env`
opam remote add lvhd git://github.com/xapi-project/thin-lvhd-opam-repo
sudo apt-get install -qq `opam install ${OPAM_PACKAGES} -e ubuntu`
opam install ${OPAM_PACKAGES}

## execute the build

cd $TRAVIS_BUILD_DIR
make
sudo ./test.sh
