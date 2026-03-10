#!/usr/bin/env perl
use 5.020;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP;
use Skein::Acceptance;
use Skein::Util qw(decode_json_file);

chdir "$FindBin::Bin/.." or die "cannot enter project: $!\n";
die "Usage: perl tools/verify.pl [ACCEPTANCE.json]\n" if @ARGV>1;
my $path=shift(@ARGV)//'evidence/acceptance.json';
my $result=Skein::Acceptance->verify('.',decode_json_file($path,32*1024*1024));
print JSON::PP->new->canonical->pretty->encode($result);
