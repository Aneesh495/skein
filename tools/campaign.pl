#!/usr/bin/env perl
use 5.020;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);
use Skein::Campaign;
use Skein::Util qw(write_json);
$|=1;
chdir "$FindBin::Bin/.." or die "cannot enter project: $!\n";

my %options = (cases => 128,functions => 256,families => 1024,seed => 'skein.acceptance/1',
    out => '.runtime/campaign.json');
GetOptions('cases=i' => \$options{cases},'functions=i' => \$options{functions},
    'families=i' => \$options{families},'seed=s' => \$options{seed},'out=s' => \$options{out})
    or die "Usage: perl tools/campaign.pl [--cases N --families N --seed S --out FILE]\n";
die "unexpected positional arguments\n" if @ARGV;
my $last = time;
my $campaign = Skein::Campaign->new(seed => $options{seed},failure_directory => '.runtime',
    progress => sub {
        my ($phase,$done,$total) = @_;
        return if time - $last < 10 && $done != $total;
        print "$phase $done/$total\n";
        $last = time;
    });
my $result = $campaign->run(%options);
write_json($options{out},$result);
print "Passed $result->{assertions} invariants across $result->{queries} causal queries.\n";
print "Receipt $result->{receipt}\nEvidence $options{out}\n";
