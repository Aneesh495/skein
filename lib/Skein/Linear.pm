package Skein::Linear;
use 5.020;
use strict;
use warnings;
use Exporter 'import';
use Skein::Rat qw(rat zero one add subr mul divr compare text is_zero);
use Skein::Util qw(integer);

our @EXPORT_OK = qw(matrix identity transpose multiply matvec solve inverse
    determinant rank rref add_matrix scale_matrix);

sub matrix {
    my ($input, %options) = @_;
    die "matrix must be an array of rows\n" unless ref($input) eq 'ARRAY';
    my $limit = integer($options{max_dimension} // 128, 'matrix dimension limit', 1, 512);
    die "matrix row limit exceeded\n" if @$input > $limit;
    die "matrix row must be an array\n" if @$input && ref($input->[0]) ne 'ARRAY';
    my $columns = @$input ? scalar @{$input->[0]} : 0;
    die "matrix column limit exceeded\n" if $columns > $limit;
    my @result;
    for my $row (@$input) {
        die "matrix row must be an array\n" unless ref($row) eq 'ARRAY';
        die "matrix is not rectangular\n" unless @$row == $columns;
        push @result, [map { rat($_) } @$row];
    }
    return \@result;
}

sub identity {
    my ($size) = @_;
    integer($size, 'identity dimension', 0, 128);
    return [map {
        my $row = $_;
        [map { $_ == $row ? one() : zero() } 0 .. $size - 1];
    } 0 .. $size - 1];
}

sub transpose {
    my ($input) = @_;
    my $a = matrix($input);
    return [] unless @$a;
    return [map {
        my $column = $_;
        [map { $_->[$column]->copy } @$a];
    } 0 .. $#{$a->[0]}];
}

sub multiply {
    my ($left, $right) = @_;
    my $a = matrix($left);
    my $b = matrix($right);
    die "matrix multiplication dimension mismatch\n"
        unless (@$a ? @{$a->[0]} : 0) == @$b;
    my $columns = @$b ? scalar @{$b->[0]} : 0;
    my @result;
    for my $row (@$a) {
        my @values;
        for my $column (0 .. $columns - 1) {
            my $value = zero();
            for my $i (0 .. $#$row) {
                $value = add($value, mul($row->[$i], $b->[$i][$column]));
            }
            push @values, $value;
        }
        push @result, \@values;
    }
    return \@result;
}

sub matvec {
    my ($a, $values) = @_;
    die "matrix vector must be an array\n" unless ref($values) eq 'ARRAY';
    my $result = multiply($a, [map { [$_] } @$values]);
    return [map { $_->[0] } @$result];
}

sub add_matrix {
    my ($left, $right) = @_;
    my $a = matrix($left);
    my $b = matrix($right);
    die "matrix addition dimension mismatch\n" unless @$a == @$b
        && (@$a ? @{$a->[0]} : 0) == (@$b ? @{$b->[0]} : 0);
    return [map {
        my $i = $_;
        [map { add($a->[$i][$_], $b->[$i][$_]) } 0 .. $#{$a->[$i]}];
    } 0 .. $#$a];
}

sub scale_matrix {
    my ($input, $value) = @_;
    my $a = matrix($input);
    return [map { [map { mul($_, $value) } @$_] } @$a];
}

sub rref {
    my ($input, %options) = @_;
    my $a = matrix($input);
    my $columns = @$a ? scalar @{$a->[0]} : 0;
    my $pivot_columns = $options{pivot_columns} // $columns;
    integer($pivot_columns, 'pivot column count', 0, $columns);
    my @pivots;
    my $row = 0;
    for my $column (0 .. $pivot_columns - 1) {
        last if $row == @$a;
        my $pivot;
        for my $candidate ($row .. $#$a) {
            if (!is_zero($a->[$candidate][$column])) {
                $pivot = $candidate;
                last;
            }
        }
        next unless defined $pivot;
        @$a[$row, $pivot] = @$a[$pivot, $row] if $row != $pivot;
        my $divisor = $a->[$row][$column];
        $a->[$row] = [map { divr($_, $divisor) } @{$a->[$row]}];
        for my $other (0 .. $#$a) {
            next if $other == $row || is_zero($a->[$other][$column]);
            my $factor = $a->[$other][$column];
            for my $j (0 .. $columns - 1) {
                $a->[$other][$j] = subr($a->[$other][$j], mul($factor, $a->[$row][$j]));
            }
        }
        push @pivots, $column;
        ++$row;
    }
    return {matrix => $a, pivots => \@pivots, rank => scalar @pivots};
}

sub rank { return rref($_[0])->{rank} }

sub solve {
    my ($input, $rhs) = @_;
    my $a = matrix($input);
    die "linear right-hand side must be an array\n" unless ref($rhs) eq 'ARRAY';
    die "linear right-hand side dimension mismatch\n" unless @$rhs == @$a;
    my $columns = @$a ? scalar @{$a->[0]} : 0;
    my $augmented = [map { [@{$a->[$_]}, rat($rhs->[$_])] } 0 .. $#$a];
    my $reduced = rref($augmented, pivot_columns => $columns);
    for my $row (@{$reduced->{matrix}}) {
        my $all_zero = 1;
        for my $column (0 .. $columns - 1) {
            $all_zero = 0 unless is_zero($row->[$column]);
        }
        die "inconsistent linear system\n" if $all_zero && !is_zero($row->[$columns]);
    }
    die "linear system has no unique solution\n" if $reduced->{rank} != $columns;
    my @solution = (zero()) x $columns;
    for my $row (0 .. $#{$reduced->{pivots}}) {
        $solution[$reduced->{pivots}[$row]] = $reduced->{matrix}[$row][$columns]->copy;
    }
    my $check = matvec($a, \@solution);
    for my $i (0 .. $#$check) {
        die "linear solution residual is nonzero\n" if compare($check->[$i], $rhs->[$i]) != 0;
    }
    return \@solution;
}

sub inverse {
    my ($input) = @_;
    my $a = matrix($input);
    die "inverse requires a square matrix\n" unless @$a == (@$a ? @{$a->[0]} : 0);
    return [] unless @$a;
    my $identity = identity(scalar @$a);
    my $augmented = [map { [@{$a->[$_]}, @{$identity->[$_]}] } 0 .. $#$a];
    my $reduced = rref($augmented, pivot_columns => scalar @$a);
    die "singular matrix\n" unless $reduced->{rank} == @$a;
    my $inverse = [map { [@$_[scalar(@$a) .. 2 * @$a - 1]] } @{$reduced->{matrix}}];
    my $product = multiply($a, $inverse);
    for my $i (0 .. $#$a) {
        for my $j (0 .. $#$a) {
            die "inverse residual is nonzero\n" if compare($product->[$i][$j], $i == $j ? 1 : 0) != 0;
        }
    }
    return $inverse;
}

sub determinant {
    my ($input) = @_;
    my $a = matrix($input);
    die "determinant requires a square matrix\n" unless @$a == (@$a ? @{$a->[0]} : 0);
    my $result = one();
    for my $column (0 .. $#$a) {
        my $pivot;
        for my $row ($column .. $#$a) {
            if (!is_zero($a->[$row][$column])) {
                $pivot = $row;
                last;
            }
        }
        return zero() unless defined $pivot;
        if ($pivot != $column) {
            @$a[$pivot, $column] = @$a[$column, $pivot];
            $result = mul($result, -1);
        }
        my $value = $a->[$column][$column];
        $result = mul($result, $value);
        for my $row ($column + 1 .. $#$a) {
            next if is_zero($a->[$row][$column]);
            my $factor = divr($a->[$row][$column], $value);
            for my $j ($column + 1 .. $#$a) {
                $a->[$row][$j] = subr($a->[$row][$j], mul($factor, $a->[$column][$j]));
            }
            $a->[$row][$column] = zero();
        }
    }
    return $result;
}

1;
