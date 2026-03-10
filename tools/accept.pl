#!/usr/bin/env perl
use 5.020;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long qw(GetOptions);
use Skein::Acceptance;
use Skein::Util qw(write_json);

$|=1;
chdir "$FindBin::Bin/.." or die "cannot enter project: $!\n";
my %options=(out=>'.runtime/acceptance.json',cases=>128,families=>2048,repetitions=>3);
GetOptions('out=s'=>\$options{out},'cases=i'=>\$options{cases},'families=i'=>\$options{families},
    'repetitions=i'=>\$options{repetitions},'seed=s'=>\$options{seed}) or die "invalid acceptance options\n";
die "unexpected positional arguments\n" if @ARGV;
my $bundle=Skein::Acceptance->run('.',%options);
write_json($options{out},$bundle);
my $verified=Skein::Acceptance->verify('.', $bundle);
print "Frozen acceptance verified: $verified->{source_sha256}\nEvidence $options{out}\n";
