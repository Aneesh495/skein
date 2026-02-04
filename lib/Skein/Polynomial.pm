package Skein::Polynomial;
use 5.020;
use strict;
use warnings;
use Skein::Rat qw(rat zero one add subr mul text compare is_zero);
use Skein::Util qw(identifier integer);

sub new {
    my ($class, $variables, $terms, %options) = @_;
    die "polynomial variables must be an array\n" unless ref($variables) eq 'ARRAY';
    die "polynomial terms must be an object\n" unless ref($terms) eq 'HASH';
    my %seen;
    for my $name (@$variables) {
        identifier($name, 'polynomial variable');
        die "duplicate polynomial variable\n" if $seen{$name}++;
    }
    my $self = bless {variables => [@$variables], terms => {},
        max_terms => integer($options{max_terms} // 50_000, 'polynomial term limit', 1, 500_000),
        max_products => integer($options{max_products} // 1_000_000, 'polynomial product limit', 1, 10_000_000)}, $class;
    die "polynomial term limit exceeded\n" if keys(%$terms) > $self->{max_terms};
    for my $key (keys %$terms) {
        my @powers = length($key) ? split(/,/, $key, -1) : ();
        die "invalid polynomial monomial dimension\n" unless @powers == @$variables;
        integer($_, 'polynomial exponent', 0, 128) for @powers;
        my $coefficient = rat($terms->{$key});
        next if is_zero($coefficient);
        my $canonical = join ',', map { 0 + $_ } @powers;
        $self->{terms}{$canonical} = add($self->{terms}{$canonical} // zero(), $coefficient);
    }
    delete $self->{terms}{$_} for grep { is_zero($self->{terms}{$_}) } keys %{$self->{terms}};
    return $self;
}

sub _options {
    my ($self) = @_;
    return (max_terms => $self->{max_terms}, max_products => $self->{max_products});
}

sub constant {
    my ($class, $variables, $value, %options) = @_;
    return $class->new($variables, {join(',', (0) x @$variables) => $value}, %options);
}

sub variable {
    my ($class, $variables, $name, %options) = @_;
    my %position = map { $variables->[$_] => $_ } 0 .. $#$variables;
    die "unknown polynomial variable '$name'\n" unless exists $position{$name};
    my @powers = (0) x @$variables;
    $powers[$position{$name}] = 1;
    return $class->new($variables, {join(',', @powers) => 1}, %options);
}

sub variables { return [@{$_[0]{variables}}] }
sub terms { return {map { $_ => text($_[0]{terms}{$_}) } keys %{$_[0]{terms}}} }
sub term_count { return scalar keys %{$_[0]{terms}} }

sub _compatible {
    my ($self, $other) = @_;
    die "incompatible polynomial variable order\n" unless ref($other) && $other->isa(__PACKAGE__)
        && join(',', @{$self->{variables}}) eq join(',', @{$other->{variables}});
}

sub plus {
    my ($self, $other) = @_;
    $self->_compatible($other);
    my %terms = %{$self->{terms}};
    for my $key (keys %{$other->{terms}}) {
        $terms{$key} = add($terms{$key} // zero(), $other->{terms}{$key});
    }
    return ref($self)->new($self->{variables}, \%terms, $self->_options);
}

sub scale {
    my ($self, $value) = @_;
    my %terms = map { $_ => mul($self->{terms}{$_}, $value) } keys %{$self->{terms}};
    return ref($self)->new($self->{variables}, \%terms, $self->_options);
}

sub minus { return $_[0]->plus($_[1]->scale(-1)) }

sub times {
    my ($self, $other) = @_;
    $self->_compatible($other);
    die "polynomial product limit exceeded\n"
        if $self->term_count * $other->term_count > $self->{max_products};
    my %terms;
    my %left_powers = map { $_ => [split /,/, $_] } keys %{$self->{terms}};
    my %right_powers = map { $_ => [split /,/, $_] } keys %{$other->{terms}};
    for my $left (keys %left_powers) {
        for my $right (keys %right_powers) {
            my @powers = map { $left_powers{$left}[$_] + $right_powers{$right}[$_] }
                0 .. $#{$self->{variables}};
            my $key = join ',', @powers;
            $terms{$key} = add($terms{$key} // zero(), mul($self->{terms}{$left}, $other->{terms}{$right}));
            die "polynomial term limit exceeded\n" if keys(%terms) > $self->{max_terms};
        }
    }
    return ref($self)->new($self->{variables}, \%terms, $self->_options);
}

sub derivative {
    my ($self, $name) = @_;
    my %position = map { $self->{variables}[$_] => $_ } 0 .. $#{$self->{variables}};
    die "unknown derivative variable '$name'\n" unless exists $position{$name};
    my %terms;
    for my $key (keys %{$self->{terms}}) {
        my @powers = split /,/, $key;
        my $power = $powers[$position{$name}];
        next unless $power;
        --$powers[$position{$name}];
        $terms{join(',', @powers)} = mul($self->{terms}{$key}, $power);
    }
    return ref($self)->new($self->{variables}, \%terms, $self->_options);
}

sub evaluate {
    my ($self, $values) = @_;
    my @values;
    for my $name (@{$self->{variables}}) {
        die "polynomial value missing '$name'\n" unless exists $values->{$name};
        push @values, rat($values->{$name});
    }
    my $result = zero();
    for my $key (keys %{$self->{terms}}) {
        my @powers = length($key) ? split(/,/, $key) : ();
        my $term = $self->{terms}{$key}->copy;
        for my $i (0 .. $#powers) {
            my $power = $values[$i]->copy;
            $power->bpow($powers[$i]);
            $term = mul($term, $power);
        }
        $result = add($result, $term);
    }
    return $result;
}

sub specialize {
    my ($self, $values) = @_;
    my %scope = map { $_ => 1 } @{$self->{variables}};
    die "specialization names unknown variable\n" if grep { !$scope{$_} } keys %$values;
    my @remaining = grep { !exists $values->{$_} } @{$self->{variables}};
    my %terms;
    for my $key (keys %{$self->{terms}}) {
        my @powers = split /,/, $key;
        my @new_powers;
        my $coefficient = $self->{terms}{$key}->copy;
        for my $i (0 .. $#{$self->{variables}}) {
            my $name = $self->{variables}[$i];
            if (exists $values->{$name}) {
                my $power = rat($values->{$name});
                $power->bpow($powers[$i]);
                $coefficient = mul($coefficient, $power);
            } else {
                push @new_powers, $powers[$i];
            }
        }
        my $new_key = join ',', @new_powers;
        $terms{$new_key} = add($terms{$new_key} // zero(), $coefficient);
    }
    return ref($self)->new(\@remaining, \%terms, $self->_options);
}

sub multilinear {
    my ($self) = @_;
    for my $key (keys %{$self->{terms}}) {
        return 0 if grep { $_ > 1 } split /,/, $key;
    }
    return 1;
}

sub from_bdd {
    my ($class, $bdd, $root, %options) = @_;
    my $variables = $bdd->variables;
    my %result = (0 => $class->constant($variables, 0, %options),
        1 => $class->constant($variables, 1, %options));
    for my $id (@{$bdd->reachable($root)}) {
        next if $id < 2;
        my ($rank, $low, $high) = @{$bdd->node($id)};
        my $p = $class->variable($variables, $variables->[$rank], %options);
        $result{$id} = $result{$low}->plus($p->times($result{$high}->minus($result{$low})));
    }
    die "reliability polynomial is not multilinear\n" unless $result{$root}->multilinear;
    return $result{$root};
}

sub render {
    my ($self) = @_;
    return '0' unless $self->term_count;
    my @terms;
    for my $key (sort keys %{$self->{terms}}) {
        my @powers = split /,/, $key;
        my @factors;
        for my $i (0 .. $#powers) {
            next unless $powers[$i];
            push @factors, $self->{variables}[$i] . ($powers[$i] > 1 ? '^' . $powers[$i] : '');
        }
        my $coefficient = text($self->{terms}{$key});
        push @terms, $coefficient . (@factors ? '*' . join('*', @factors) : '');
    }
    return join(' + ', @terms);
}

1;
