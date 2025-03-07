# Configure the Makefile. Running this script will generate the Makefile.
require 'mkmf'
$CFLAGS << ' -Wall -O3'
create_makefile('cinne')