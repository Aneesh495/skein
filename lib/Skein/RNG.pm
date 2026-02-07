package Skein::RNG;
use 5.020;
use strict;
use warnings;
use Digest::SHA qw(sha256);
use Math::BigInt;
use Skein::Rat qw(probability);
use Skein::Util ();

sub new {
    my ($class, $seed) = @_;
    $seed //= 1;
    die "random seed must be a bounded scalar\n" if ref($seed) || length($seed) > 1024;
    return bless {seed => sha256("$seed"), counter => 0, buffer => '', draws => 0}, $class;
}

sub bytes {
    my ($self, $count) = @_;
    Skein::Util::integer($count, 'random byte count', 0, 1_048_576);
    while (length($self->{buffer}) < $count) {
        die "random counter exhausted\n" if $self->{counter} >= 4_294_967_295;
        my $block = sha256("skein.rng/1\0" . $self->{seed} . pack('N', $self->{counter}++));
        $self->{buffer} .= $block;
    }
    return substr($self->{buffer}, 0, $count, '');
}

sub below {
    my ($self, $bound) = @_;
    my $n = Math::BigInt->new("$bound");
    die "invalid random bound\n" if $n->is_nan || $n->is_inf || $n->bcmp(1) < 0;
    return Math::BigInt->new(0) if $n->is_one;
    my $bits = length($n->copy->bdec->as_bin) - 2;
    die "random bound bit limit exceeded\n" if $bits > 4096;
    my $count = int(($bits + 7) / 8);
    my $extra = 8 * $count - $bits;
    for (1 .. 10_000) {
        my @bytes = unpack 'C*', $self->bytes($count);
        $bytes[0] &= (255 >> $extra);
        my $value = Math::BigInt->from_hex('0x' . unpack('H*', pack('C*', @bytes)));
        ++$self->{draws};
        return $value if $value->bcmp($n) < 0;
    }
    die "random rejection limit exceeded\n";
}

sub integer {
    my ($self, $bound) = @_;
    Skein::Util::integer($bound, 'random integer bound', 1, 1_000_000_000);
    return 0 + $self->below($bound)->bstr;
}

sub bernoulli {
    my ($self, $p) = @_;
    my $r = probability($p);
    return 0 if $r->is_zero;
    return 1 if $r->is_one;
    my $n = $r->numerator;
    my $d = $r->denominator;
    return $self->below($d->bstr)->bcmp($n) < 0 ? 1 : 0;
}

sub draws { return $_[0]{draws} }

1;
