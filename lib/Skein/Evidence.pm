package Skein::Evidence;
use 5.020;
use strict;
use warnings;
use File::Find qw(find);
use File::Spec;
use Digest::SHA;
use Skein::Util qw(check_keys digest canonical_json integer deep_copy write_json decode_json_file);

my @ROOTS = qw(lib bin tools t examples docs .github);
my @FILES = qw(README.md LICENSE Makefile.PL MANIFEST .gitignore);

sub _relative {
    my ($path) = @_;
    die "invalid evidence relative path\n" unless defined($path) && !ref($path)
        && $path =~ /\A[A-Za-z0-9_.\/-]+\z/ && $path !~ /\A\// && $path !~ /\\/;
    my @parts = split m{/},$path,-1;
    die "invalid evidence path component\n" if grep { $_ eq '' || $_ eq '.' || $_ eq '..' } @parts;
    return $path;
}

sub _path {
    my ($root, $relative) = @_;
    _relative($relative);
    return File::Spec->catfile($root,split m{/},$relative);
}

sub file_record {
    my ($class, $root, $relative) = @_;
    my $path = _path($root,$relative);
    die "evidence does not follow symlinks\n" if -l $path;
    die "evidence file missing: $relative\n" unless -f $path;
    open my $handle,'<:raw',$path or die "cannot hash $relative: $!\n";
    my $sha = Digest::SHA->new(256);
    my $bytes = 0;
    while (1) {
        my $count = read($handle,my $chunk,65536);
        die "cannot read evidence file $relative: $!\n" unless defined $count;
        last unless $count;
        $sha->add($chunk);
        $bytes += $count;
        die "evidence file byte limit exceeded\n" if $bytes > 64*1024*1024;
    }
    close $handle or die "cannot close evidence file $relative: $!\n";
    return {path => $relative,bytes => $bytes,sha256 => $sha->hexdigest};
}

sub inventory {
    my ($class, $root) = @_;
    my @paths;
    for my $relative (@FILES) {
        push @paths,$relative if -f _path($root,$relative);
    }
    for my $directory (@ROOTS) {
        my $base = _path($root,$directory);
        next unless -d $base;
        find({no_chdir => 1,wanted => sub {
            my $path = $File::Find::name;
            die "source inventory does not follow symlinks\n" if -l $path;
            return unless -f $path;
            my $relative = File::Spec->abs2rel($path,$root);
            $relative =~ s{\\}{/}g;
            _relative($relative);
            push @paths,$relative;
        }},$base);
    }
    return [sort @paths];
}

sub source_manifest {
    my ($class, $root) = @_;
    $root = File::Spec->rel2abs($root);
    my $records = [map { $class->file_record($root,$_) } @{$class->inventory($root)}];
    my $payload = {schema => 'skein.source/1',files => $records,
        policy => 'All files in lib, bin, tools, t, examples, docs and .github plus root metadata. Runtime, build and evidence outputs are excluded.'};
    return {%$payload,sha256 => digest($payload)};
}

sub verify_source {
    my ($class, $root, $manifest) = @_;
    check_keys($manifest,[qw(schema files policy sha256)],[qw(schema files policy sha256)],'source manifest');
    my %payload = %$manifest;
    delete $payload{sha256};
    die "source manifest integrity mismatch\n" unless digest(\%payload) eq $manifest->{sha256};
    die "unsupported source manifest\n" unless $manifest->{schema} eq 'skein.source/1';
    die "source manifest files must be an array\n" unless ref($manifest->{files}) eq 'ARRAY';
    my %seen;
    for my $record (@{$manifest->{files}}) {
        check_keys($record,[qw(path bytes sha256)],[qw(path bytes sha256)],'source file record');
        _relative($record->{path});
        die "duplicate source file record\n" if $seen{$record->{path}}++;
        integer($record->{bytes},'source byte count',0,64*1024*1024);
        die "invalid source file hash\n" unless !ref($record->{sha256}) && $record->{sha256} =~ /\A[0-9a-f]{64}\z/;
    }
    my $current = $class->source_manifest($root);
    die "source inventory or contents changed\n" unless canonical_json($current) eq canonical_json($manifest);
    return {verified => 1,files => scalar @{$manifest->{files}},source_sha256 => $manifest->{sha256}};
}

sub bundle {
    my ($class, $source, $data) = @_;
    die "evidence data must be an object\n" unless ref($data) eq 'HASH';
    my $payload = {schema => 'skein.acceptance/1',source => deep_copy($source),
        data => deep_copy($data),trust => 'Unsigned reproducibility receipt. Integrity is not authenticity.'};
    return {payload => $payload,sha256 => digest($payload)};
}

sub verify_bundle {
    my ($class, $root, $bundle) = @_;
    check_keys($bundle,[qw(payload sha256)],[qw(payload sha256)],'acceptance envelope');
    check_keys($bundle->{payload},[qw(schema source data trust)],[qw(schema source data trust)],'acceptance payload');
    die "acceptance envelope integrity mismatch\n" unless digest($bundle->{payload}) eq $bundle->{sha256};
    die "unsupported acceptance schema\n" unless $bundle->{payload}{schema} eq 'skein.acceptance/1';
    my $source = $class->verify_source($root,$bundle->{payload}{source});
    my $data = $bundle->{payload}{data};
    die "acceptance data must be an object\n" unless ref($data) eq 'HASH';
    die "acceptance was not successful\n" unless $data->{passed} && $data->{tests}{passed}
        && $data->{campaign}{passed} && $data->{tests}{assertions} > 0 && $data->{campaign}{assertions} > 0;
    return {%$source,envelope_sha256 => $bundle->{sha256},
        tests => $data->{tests}{assertions},campaign_assertions => $data->{campaign}{assertions},
        verification_scope => 'Current source bytes, artifact integrity and reported success. Scientific result certificates are checked separately.'};
}

1;
