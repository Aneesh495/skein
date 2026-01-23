package Skein::Factor;
use 5.020;
use strict;
use warnings;
use Skein::Rat qw(rat probability zero one add mul divr text compare is_zero);
use Skein::Util qw(identifier integer boolean);

sub new {
    my ($class, $variables, $rows, %options) = @_;
    die "factor scope must be an array\n" unless ref($variables) eq 'ARRAY';
    die "factor rows must be an object\n" unless ref($rows) eq 'HASH';
    die "factor scope too large\n" if @$variables > 128;
    my %seen;
    for my $name (@$variables) {
        identifier($name, 'factor variable');
        die "duplicate factor variable '$name'\n" if $seen{$name}++;
    }
    my $self = bless {
        variables => [sort @$variables], rows => {},
        max_rows => integer($options{max_rows} // 250_000, 'factor row limit', 1, 2_000_000),
        max_ops => integer($options{max_ops} // 2_000_000, 'factor join limit', 1, 20_000_000),
    }, $class;
    die "factor row limit exceeded\n" if keys(%$rows) > $self->{max_rows};
    my %position = map { $variables->[$_] => $_ } 0 .. $#$variables;
    my @permutation = map { $position{$_} } @{$self->{variables}};
    for my $key (sort keys %$rows) {
        die "invalid factor assignment\n" unless length($key) == @$variables && $key =~ /\A[01]*\z/;
        my $weight = rat($rows->{$key});
        die "negative factor weight\n" if compare($weight, 0) < 0;
        next if is_zero($weight);
        my $canonical = join '', map { substr($key, $_, 1) } @permutation;
        $self->{rows}{$canonical} = $weight;
    }
    return $self;
}

sub scalar_factor {
    my ($class, $weight, %options) = @_;
    return $class->new([], {'' => $weight}, %options);
}

sub from_function {
    my ($class, $variables, $function, %options) = @_;
    my $max_scope = integer(delete($options{max_scope}) // 18, 'factor local scope limit', 0, 22);
    die "factor local scope limit exceeded\n" if @$variables > $max_scope;
    my $max_rows = $options{max_rows} // 250_000;
    my %rows;
    for my $mask (0 .. (2 ** @$variables) - 1) {
        my %assignment;
        my $key = '';
        for my $index (0 .. $#$variables) {
            my $bit = ($mask >> $index) & 1;
            $assignment{$variables->[$index]} = $bit;
            $key .= $bit;
        }
        my $weight = rat($function->(\%assignment));
        next if is_zero($weight);
        die "factor row limit exceeded\n" if keys(%rows) >= $max_rows;
        $rows{$key} = $weight;
    }
    return $class->new($variables, \%rows, %options);
}

sub variables { return [@{$_[0]{variables}}] }
sub row_count { return scalar keys %{$_[0]{rows}} }
sub rows { return {map { $_ => text($_[0]{rows}{$_}) } keys %{$_[0]{rows}}} }

sub _options {
    my ($self, $other) = @_;
    return (max_rows => $self->{max_rows}, max_ops => $self->{max_ops}) unless $other;
    return (
        max_rows => $self->{max_rows} < $other->{max_rows} ? $self->{max_rows} : $other->{max_rows},
        max_ops => $self->{max_ops} < $other->{max_ops} ? $self->{max_ops} : $other->{max_ops},
    );
}

sub clone {
    my ($self) = @_;
    return ref($self)->new($self->{variables}, $self->{rows}, $self->_options);
}

sub value {
    my ($self, $assignment) = @_;
    my $key = '';
    for my $name (@{$self->{variables}}) {
        die "missing factor variable '$name'\n" unless exists $assignment->{$name};
        $key .= boolean($assignment->{$name});
    }
    return exists($self->{rows}{$key}) ? $self->{rows}{$key}->copy : zero();
}

sub multiply {
    my ($self, $other) = @_;
    die "factor join requires another factor\n" unless ref($other) && $other->isa(__PACKAGE__);
    my %left_position = map { $self->{variables}[$_] => $_ } 0 .. $#{$self->{variables}};
    my %right_position = map { $other->{variables}[$_] => $_ } 0 .. $#{$other->{variables}};
    my @common = sort grep { exists $right_position{$_} } keys %left_position;
    my %all = (%left_position, %right_position);
    my @variables = sort keys %all;
    my @left_common = map { $left_position{$_} } @common;
    my @right_common = map { $right_position{$_} } @common;
    my %buckets;
    for my $key (keys %{$other->{rows}}) {
        my $common_key = join '', map { substr($key, $_, 1) } @right_common;
        push @{$buckets{$common_key}}, $key;
    }
    my @projection = map {
        exists($left_position{$_}) ? [0, $left_position{$_}] : [1, $right_position{$_}]
    } @variables;
    my %options = $self->_options($other);
    my %rows;
    my $operations = 0;
    for my $left_key (sort keys %{$self->{rows}}) {
        my $common_key = join '', map { substr($left_key, $_, 1) } @left_common;
        for my $right_key (@{$buckets{$common_key} // []}) {
            die "factor join operation limit exceeded\n" if ++$operations > $options{max_ops};
            my @keys = ($left_key, $right_key);
            my $key = join '', map { substr($keys[$_->[0]], $_->[1], 1) } @projection;
            my $weight = mul($self->{rows}{$left_key}, $other->{rows}{$right_key});
            $rows{$key} = add($rows{$key} // zero(), $weight);
            die "factor row limit exceeded\n" if keys(%rows) > $options{max_rows};
        }
    }
    return ref($self)->new(\@variables, \%rows, %options);
}

sub sum_out {
    my ($self, $names) = @_;
    $names = [$names] unless ref($names) eq 'ARRAY';
    my %scope = map { $_ => 1 } @{$self->{variables}};
    my %remove;
    for my $name (@$names) {
        die "cannot eliminate unknown factor variable '$name'\n" unless $scope{$name};
        $remove{$name} = 1;
    }
    my @keep_indices = grep { !$remove{$self->{variables}[$_]} } 0 .. $#{$self->{variables}};
    my @variables = @{$self->{variables}}[@keep_indices];
    my %rows;
    for my $key (keys %{$self->{rows}}) {
        my $projected = join '', map { substr($key, $_, 1) } @keep_indices;
        $rows{$projected} = add($rows{$projected} // zero(), $self->{rows}{$key});
    }
    return ref($self)->new(\@variables, \%rows, $self->_options);
}

sub condition {
    my ($self, $assignment) = @_;
    die "factor evidence must be an object\n" unless ref($assignment) eq 'HASH';
    my %scope = map { $_ => 1 } @{$self->{variables}};
    for my $name (keys %$assignment) {
        die "unknown factor evidence variable '$name'\n" unless $scope{$name};
        boolean($assignment->{$name});
    }
    my @keep_indices = grep { !exists $assignment->{$self->{variables}[$_]} } 0 .. $#{$self->{variables}};
    my @variables = @{$self->{variables}}[@keep_indices];
    my %rows;
    ROW: for my $key (keys %{$self->{rows}}) {
        for my $index (0 .. $#{$self->{variables}}) {
            my $name = $self->{variables}[$index];
            next ROW if exists($assignment->{$name}) && substr($key, $index, 1) != $assignment->{$name};
        }
        my $projected = join '', map { substr($key, $_, 1) } @keep_indices;
        $rows{$projected} = $self->{rows}{$key};
    }
    return ref($self)->new(\@variables, \%rows, $self->_options);
}

sub total {
    my ($self) = @_;
    my $total = zero();
    $total = add($total, $_) for values %{$self->{rows}};
    return $total;
}

sub normalize {
    my ($self) = @_;
    my $total = $self->total;
    die "cannot normalize zero-mass factor\n" if is_zero($total);
    my %rows = map { $_ => divr($self->{rows}{$_}, $total) } keys %{$self->{rows}};
    return ref($self)->new($self->{variables}, \%rows, $self->_options);
}

sub rename {
    my ($self, $mapping) = @_;
    my @variables = map { exists($mapping->{$_}) ? $mapping->{$_} : $_ } @{$self->{variables}};
    return ref($self)->new(\@variables, $self->{rows}, $self->_options);
}

1;
