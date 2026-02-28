package Skein::Spectrum;
use 5.020;
use strict;
use warnings;
use Skein::Rat qw(rat zero one add subr mul divr text compare);
use Skein::Util qw(integer boolean deep_copy);

# Uniform Walsh coefficients of g(x)=1-2*f(x). Subset indices use bit i
# for variables[i]. No floating point enters the transform or reconstruction.
sub new {
    my ($class, $variables, $table, %options) = @_;
    die "spectrum variables must be an array\n" unless ref($variables) eq 'ARRAY';
    my $limit = integer($options{max_variables} // 16,'spectral variable limit',0,20);
    die "spectral variable limit exceeded\n" if @$variables > $limit;
    my %seen;
    for my $name (@$variables) {
        Skein::Util::identifier($name,'spectral variable');
        die "duplicate spectral variable\n" if $seen{$name}++;
    }
    die "truth table must be an array\n" unless ref($table) eq 'ARRAY';
    die "truth table dimension mismatch\n" unless @$table == 2 ** @$variables;
    my @values = map { 1 - 2 * boolean($_) } @$table;
    _transform(\@values);
    my $dimension = scalar @values;
    my @coefficients = map { divr($_,$dimension) } @values;
    my $self = bless {variables => [@$variables],coefficients => \@coefficients,
        table => [map { boolean($_) } @$table]},$class;
    my $energy = zero();
    $energy = add($energy,mul($_,$_)) for @coefficients;
    die "spectral Parseval invariant failed\n" unless compare($energy,one()) == 0;
    return $self;
}

sub _transform {
    my ($values) = @_;
    for (my $width = 1; $width < @$values; $width *= 2) {
        for (my $base = 0; $base < @$values; $base += 2*$width) {
            for my $offset (0 .. $width - 1) {
                my $left = $values->[$base+$offset];
                my $right = $values->[$base+$offset+$width];
                $values->[$base+$offset] = add($left,$right);
                $values->[$base+$offset+$width] = subr($left,$right);
            }
        }
    }
    return $values;
}

sub from_bdd {
    my ($class, $bdd, $root, %options) = @_;
    my $variables = $bdd->variables;
    my $limit = integer($options{max_variables} // 16,'spectral variable limit',0,20);
    die "spectral variable limit exceeded\n" if @$variables > $limit;
    my @table;
    for my $mask (0 .. 2 ** @$variables - 1) {
        my %values = map { $variables->[$_] => (($mask >> $_) & 1) } 0 .. $#$variables;
        push @table,$bdd->evaluate($root,\%values);
    }
    return $class->new($variables,\@table,%options);
}

sub coefficients {
    my ($self) = @_;
    my @rows;
    for my $mask (0 .. $#{$self->{coefficients}}) {
        next if $self->{coefficients}[$mask]->is_zero;
        my @subset = map { $self->{variables}[$_] }
            grep { ($mask >> $_) & 1 } 0 .. $#{$self->{variables}};
        push @rows,{mask => $mask,subset => \@subset,coefficient => text($self->{coefficients}[$mask])};
    }
    return \@rows;
}

sub reconstruct {
    my ($self) = @_;
    my @values = map { $_->copy } @{$self->{coefficients}};
    _transform(\@values);
    my @table;
    for my $value (@values) {
        die "spectral inverse is not Boolean\n" unless compare($value,1) == 0 || compare($value,-1) == 0;
        push @table,compare($value,-1) == 0 ? 1 : 0;
    }
    return \@table;
}

sub probability {
    my ($self, $priors) = @_;
    die "spectral priors must be an object\n" unless ref($priors) eq 'HASH';
    my $variables = $self->{variables};
    die "spectral priors do not match variables\n" unless keys(%$priors) == @$variables;
    my @moments;
    for my $name (@$variables) {
        die "spectral prior missing\n" unless exists $priors->{$name};
        push @moments,subr(1,mul(2,Skein::Rat::probability($priors->{$name})));
    }
    my $expectation = zero();
    for my $mask (0 .. $#{$self->{coefficients}}) {
        my $term = $self->{coefficients}[$mask]->copy;
        for my $i (0 .. $#$variables) {
            $term = mul($term,$moments[$i]) if ($mask >> $i) & 1;
        }
        $expectation = add($expectation,$term);
    }
    return text(divr(subr(1,$expectation),2));
}

sub influence {
    my ($self) = @_;
    my %result = map { $_ => zero() } @{$self->{variables}};
    for my $mask (0 .. $#{$self->{coefficients}}) {
        my $energy = mul($self->{coefficients}[$mask],$self->{coefficients}[$mask]);
        for my $i (0 .. $#{$self->{variables}}) {
            next unless ($mask >> $i) & 1;
            my $name = $self->{variables}[$i];
            $result{$name} = add($result{$name},$energy);
        }
    }
    return {map { $_ => text($result{$_}) } sort keys %result};
}

sub degree_energy {
    my ($self) = @_;
    my @energies = map { zero() } 0 .. @{$self->{variables}};
    for my $mask (0 .. $#{$self->{coefficients}}) {
        my $degree = 0;
        $degree += ($mask >> $_) & 1 for 0 .. $#{$self->{variables}};
        my $energy = mul($self->{coefficients}[$mask],$self->{coefficients}[$mask]);
        $energies[$degree] = add($energies[$degree],$energy);
    }
    return [map { text($_) } @energies];
}

sub noise_sensitivity {
    my ($self, $flip_probability) = @_;
    my $p = Skein::Rat::probability($flip_probability);
    my $rho = subr(1,mul(2,$p));
    my $energies = $self->degree_energy;
    my $power = one();
    my $correlation = zero();
    for my $energy (@$energies) {
        $correlation = add($correlation,mul($energy,$power));
        $power = mul($power,$rho);
    }
    return {flip_probability => text($p),correlation => text($correlation),
        disagreement_probability => text(divr(subr(1,$correlation),2)),
        population => 'uniform independent input bits with independent symmetric flips'};
}

sub profile {
    my ($self, %options) = @_;
    return {schema => 'skein.spectrum/1',variables => [@{$self->{variables}}],
        sign_convention => 'g=1-2*f; chi_S=product(1-2*x_i)',
        coefficients => $self->coefficients,degree_energy => $self->degree_energy,
        influence => $self->influence,
        noise => $self->noise_sensitivity($options{flip_probability} // '1/10')};
}

1;
