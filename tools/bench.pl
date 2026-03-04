#!/usr/bin/env perl
use 5.020;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long qw(GetOptions);
use Skein::Benchmark;
use Skein::Util qw(write_json);

my %options = (size => 256,repetitions => 3,max_nodes => 20_000,out => '.runtime/benchmark.json');
GetOptions('size=i' => \$options{size},'repetitions=i' => \$options{repetitions},
    'max-nodes=i' => \$options{max_nodes},'out=s' => \$options{out}) or die "invalid benchmark options\n";
die "unexpected positional arguments\n" if @ARGV;
my $result = Skein::Benchmark->run(%options,progress => sub {
    my ($name,$run,$total) = @_;
    print "$name $run/$total\n";
});
write_json($options{out},$result);
print "Exact closed forms checked. Raw measurements: $options{out}\n";
