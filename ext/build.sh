# Generate the Makefile
ruby extconf.rb

# Build the C extension
LIB_DIR=../lib
mkdir -p $LIB_DIR
make
cp cinne.so $LIB_DIR/cinne.so
make clean