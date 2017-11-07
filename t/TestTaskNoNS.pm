#-------------------------------------------------------------------------------
# A test task class with no prepended namespace (e.g. t::TestTask) so that the
# include path is required to find it.
#-------------------------------------------------------------------------------
package TestTaskNoNS;

use strict;
use warnings;

sub new {
  my ($class, @args) = @_;
  return bless {}, $class;
}

sub run {
  return 42;
}

1;
