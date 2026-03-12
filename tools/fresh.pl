#!/usr/bin/env perl
use 5.020;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd qw(getcwd);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;
use File::Copy qw(copy);
use Skein::Evidence;

$|=1;
my $root=File::Spec->rel2abs("$FindBin::Bin/..");
my $previous=getcwd;
my $target=tempdir('skein fresh XXXXXXXX',TMPDIR=>1,CLEANUP=>1);
for my $relative (@{Skein::Evidence->inventory($root)}) {
    my $from=File::Spec->catfile($root,split m{/},$relative);
    my $to=File::Spec->catfile($target,split m{/},$relative);
    make_path(dirname($to));
    copy($from,$to) or die "cannot copy $relative: $!\n";
}
die "fresh checkout inherited runtime state\n" if -e "$target/.runtime";
chdir $target or die "cannot enter fresh checkout: $!\n";
system($^X,'bin/skein','demo');
die "fresh demo failed with status $?\n" if $?;
system($^X,'tools/check.pl');
die "fresh verification failed with status $?\n" if $?;
die "fresh demo did not write a report\n" unless -s '.runtime/demo.html';
chdir $previous or die "cannot restore checkout: $!\n";
print "Fresh source copy, including a path with spaces, passed without generated state.\n";
