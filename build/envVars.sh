# extablish env vars for make file
export F_MASTER=/home/cbaker/Hydro/SUMMAapptainer/summa 
export FC=gfortran
export FC_EXE=gfortran
export INCLUDES='-I/usr/include -I/usr/local/inclde'
export LIBRARIES='-L/usr/lib -lnetcdff -L/usr/lib/x86_64-linux-gnu -llapack -lblas'

# Compile, DONT USE `make -j n` it will cause errors
make clean
make check
make 

cp ../bin/summa.exe ../../case_studies/