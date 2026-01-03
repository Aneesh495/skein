package Skein::Util;
use 5.020;
use strict;
use warnings;
use Exporter 'import';
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempfile);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Encode qw(decode encode FB_CROAK);

our @EXPORT_OK = qw(canonical_json decode_json_file read_text write_text
    write_json digest identifier integer boolean check_keys deep_copy
    xml_escape html_escape combinations powerset);

sub canonical_json {
    return JSON::PP->new->canonical->utf8->allow_nonref->encode($_[0]);
}

sub digest {
    return sha256_hex(canonical_json($_[0]));
}

sub read_text {
    my ($path, $limit) = @_;
    $limit //= 4 * 1024 * 1024;
    integer($limit, 'byte limit', 1, 64 * 1024 * 1024);
    open my $file, '<:raw', $path or die "cannot read $path: $!\n";
    my $data = '';
    while (1) {
        my $count = read($file, my $chunk, 65536);
        die "cannot read $path: $!\n" unless defined $count;
        last unless $count;
        $data .= $chunk;
        die "file exceeds byte limit: $path\n" if length($data) > $limit;
    }
    close $file or die "cannot close $path: $!\n";
    return decode('UTF-8', $data, FB_CROAK);
}

sub write_text {
    my ($path, $data) = @_;
    die "output must be text\n" if ref($data) || !defined($data);
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my ($file, $temp) = tempfile('.skein-XXXXXXXX', DIR => $dir, UNLINK => 0);
    binmode $file, ':raw';
    my $ok = eval {
        print {$file} encode('UTF-8', $data, FB_CROAK)
            or die "cannot write $path: $!\n";
        close $file or die "cannot close $path: $!\n";
        rename $temp, $path or die "cannot publish $path: $!\n";
        1;
    };
    my $error = $@;
    if (!$ok) {
        close $file;
        unlink $temp;
        die $error;
    }
    return $path;
}

sub write_json {
    my ($path, $value) = @_;
    my $json = JSON::PP->new->canonical->pretty->allow_nonref->encode($value);
    return write_text($path, $json);
}

sub decode_json_file {
    my ($path, $limit) = @_;
    my $raw = read_text($path, $limit);
    my $data = eval { JSON::PP->new->max_depth(128)->decode($raw) };
    die "invalid JSON in $path: $@" if $@;
    return $data;
}

sub identifier {
    my ($value, $what) = @_;
    $what //= 'identifier';
    die "invalid $what\n" unless defined($value) && !ref($value)
        && $value =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/ && length($value) <= 128;
    return $value;
}

sub integer {
    my ($value, $what, $min, $max) = @_;
    $what //= 'integer';
    $min //= 0;
    $max //= 1_000_000_000;
    die "invalid $what\n" unless defined($value) && !ref($value)
        && $value =~ /\A\d+\z/ && length($value) <= 16
        && $value >= $min && $value <= $max;
    return 0 + $value;
}

sub boolean {
    my ($value) = @_;
    die "Boolean must be 0 or 1\n" unless defined($value) && !ref($value)
        && "$value" =~ /\A[01]\z/;
    return 0 + $value;
}

sub check_keys {
    my ($object, $allowed, $required, $what) = @_;
    $what //= 'object';
    die "$what must be an object\n" unless ref($object) eq 'HASH';
    my %allowed = map { $_ => 1 } @$allowed;
    for my $key (sort keys %$object) {
        die "unknown $what field '$key'\n" unless $allowed{$key};
    }
    for my $key (@{$required // []}) {
        die "missing $what field '$key'\n" unless exists $object->{$key};
    }
    return $object;
}

sub deep_copy {
    return JSON::PP->new->decode(canonical_json($_[0]));
}

sub xml_escape {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    $text =~ s/'/&apos;/g;
    return $text;
}

sub html_escape { return xml_escape($_[0]) }

sub combinations {
    my ($items, $size, $callback) = @_;
    integer($size, 'combination size', 0, scalar @$items);
    my @chosen;
    my $walk;
    $walk = sub {
        my ($start) = @_;
        if (@chosen == $size) {
            $callback->([@chosen]);
            return;
        }
        my $need = $size - @chosen;
        for my $i ($start .. @$items - $need) {
            push @chosen, $items->[$i];
            $walk->($i + 1);
            pop @chosen;
        }
    };
    $walk->(0);
    return;
}

sub powerset {
    my ($items, $callback, $limit) = @_;
    $limit //= 20;
    die "powerset exceeds variable limit\n" if @$items > $limit;
    combinations($items, $_, $callback) for 0 .. @$items;
    return;
}

1;
