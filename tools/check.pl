#!/usr/bin/env perl
use 5.020;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Skein::Acceptance;
use Skein::Util qw(write_json);

$|=1;
chdir "$FindBin::Bin/.." or die "cannot enter project: $!\n";
my $lint = Skein::Acceptance->lint;
my $tests = Skein::Acceptance->tests;
my $examples = Skein::Acceptance->examples;
write_json('.runtime/check.json',{passed=>1,lint=>$lint,tests=>$tests,examples=>$examples});
print "Passed $tests->{assertions} assertions in $tests->{files} files. Examples and complete-world certificates agree.\n";
