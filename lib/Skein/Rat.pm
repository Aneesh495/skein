package Skein::Rat;
use 5.020;
use strict;
use warnings;
use Exporter 'import';
use Math::BigRat;
use Scalar::Util qw(blessed);

our @EXPORT_OK = qw(rat probability add subr mul divr complement compare
    zero one sum product text decimal is_zero is_one);

sub rat {
    my ($value) = @_;
    die "rational value is undefined\n" unless defined $value;
    if (blessed($value) && $value->isa('Math::BigRat')) {
        die "non-finite rational\n" if $value->is_nan || $value->is_inf;
        return $value->copy;
    }
    die "rational must be a scalar\n" if ref $value;
    die "invalid rational '$value'\n"
        unless $value =~ /\A[+-]?(?:\d+(?:\/\d+)?|\d*\.\d+)\z/;
    die "rational literal is too long\n" if length($value) > 1024;
    my $r = Math::BigRat->new("$value");
    die "non-finite rational '$value'\n" if $r->is_nan || $r->is_inf;
    return $r;
}

sub probability {
    my ($value) = @_;
    my $r = rat($value);
    die "probability outside [0,1]\n" if $r->bcmp(0) < 0 || $r->bcmp(1) > 0;
    return $r;
}

sub zero { return Math::BigRat->new(0) }
sub one { return Math::BigRat->new(1) }
sub add { return scalar rat($_[0])->badd(rat($_[1])) }
sub subr { return scalar rat($_[0])->bsub(rat($_[1])) }
sub mul { return scalar rat($_[0])->bmul(rat($_[1])) }

sub divr {
    my ($a, $b) = @_;
    my $den = rat($b);
    die "division by zero\n" if $den->is_zero;
    my $result = rat($a);
    $result->bdiv($den);
    return $result;
}

sub complement { return scalar one()->bsub(rat($_[0])) }
sub compare { return rat($_[0])->bcmp(rat($_[1])) }
sub text { return rat($_[0])->bstr }
sub is_zero { return rat($_[0])->is_zero ? 1 : 0 }
sub is_one { return rat($_[0])->is_one ? 1 : 0 }

sub sum {
    my $result = zero();
    $result->badd(rat($_)) for @_;
    return $result;
}

sub product {
    my $result = one();
    $result->bmul(rat($_)) for @_;
    return $result;
}

sub decimal {
    my ($value, $digits) = @_;
    $digits //= 12;
    die "decimal precision must be between 1 and 100\n"
        unless $digits =~ /\A\d+\z/ && $digits >= 1 && $digits <= 100;
    my $display = rat($value)->as_float($digits)->bstr;
    if ($display =~ /\./ && $display !~ /[eE]/) {
        $display =~ s/0+\z//;
        $display =~ s/\.\z//;
    }
    return $display;
}

1;
