#!/usr/bin/env perl
use 5.020;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use File::Find qw(find);
use File::Spec;
use Digest::SHA qw(sha256_hex);
use Getopt::Long qw(GetOptions);
use Skein;
use Skein::Evidence;
use Skein::Util qw(read_text write_text write_json);

$|=1;
chdir "$FindBin::Bin/.." or die "cannot enter project: $!\n";
my $manifest_only=0;
GetOptions('manifest'=>\$manifest_only) or die "invalid package option\n";
die "unexpected positional arguments\n" if @ARGV;
my @files=@{Skein::Evidence->inventory('.')};
if (-d 'evidence') {
    find({no_chdir=>1,wanted=>sub {
        push @files,$File::Find::name if -f $File::Find::name;
    }},'evidence');
}
push @files,'MANIFEST' unless grep { $_ eq 'MANIFEST' } @files;
my %seen;
@files=sort grep { !$seen{$_}++ } @files;
write_text('MANIFEST',join("\n",@files)."\n");
if ($manifest_only) {
    print "MANIFEST contains " . scalar(@files) . " files.\n";
    exit 0;
}
my $prefix="Skein-$Skein::VERSION";
my $archive=Archive::Tar->new;
my @records;
for my $path (@files) {
    my $record=Skein::Evidence->file_record('.',$path);
    push @records,$record;
    open my $file,'<:raw',$path or die "cannot package $path: $!\n";
    local $/;
    my $bytes=<$file>;
    close $file or die "cannot close $path: $!\n";
    $archive->add_data("$prefix/$path",$bytes,{mode=>$path eq 'bin/skein'?0755:0644,
        mtime=>0,uid=>0,gid=>0,uname=>'',gname=>''});
}
write_text('.runtime/package-ready','');
my $output=".runtime/$prefix.tar.gz";
$archive->write($output,COMPRESS_GZIP) or die "cannot write release archive\n";
my $checked=Archive::Tar->new;
$checked->read($output,COMPRESS_GZIP) or die "cannot reopen release archive\n";
my @expected=map { "$prefix/$_" } @files;
my @actual=sort $checked->list_files;
die "release archive inventory mismatch\n" unless join("\n",@actual) eq join("\n",@expected);
for my $record (@records) {
    my $bytes=$checked->get_content("$prefix/$record->{path}");
    die "release archive byte mismatch\n" unless sha256_hex($bytes) eq $record->{sha256};
}
write_json('.runtime/package.json',{passed=>1,archive=>$output,files=>scalar @files,
    file_records=>\@records,method=>'Every archived byte stream and path compared with source.'});
print "Verified release archive: $output\n";
