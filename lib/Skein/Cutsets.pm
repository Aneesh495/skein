package Skein::Cutsets;
use 5.020;
use strict;
use warnings;
no warnings 'recursion';
use Skein::ZDD;
use Skein::BDD::Transform qw(restrict support);
use Skein::Rat qw(one mul probability complement text);
use Skein::Util qw(integer);

sub new {
    my ($class, $bdd, $root, %options) = @_;
    $bdd->node($root);
    return bless {bdd => $bdd, root => $root,
        max_nodes => integer($options{max_nodes} // 250_000, 'cutset node limit', 2, 2_000_000),
        max_calls => integer($options{max_calls} // 250_000, 'implicant work limit', 1, 2_000_000)}, $class;
}

sub monotonicity {
    my ($self) = @_;
    my @violations;
    for my $name (@{support($self->{bdd}, $self->{root})}) {
        my $low = restrict($self->{bdd}, $self->{root}, {$name => 0});
        my $high = restrict($self->{bdd}, $self->{root}, {$name => 1});
        my $bad = $self->{bdd}->apply('and', $low, $self->{bdd}->negate($high));
        push @violations, {variable => $name, witness_root => $bad} if $bad != 0;
    }
    return {monotone => @violations ? 0 : 1, violations => \@violations};
}

sub minimal_positive {
    my ($self) = @_;
    die "positive cut sets require a monotone event; use signed prime implicants\n"
        unless $self->monotonicity->{monotone};
    my $bdd = $self->{bdd};
    my $zdd = Skein::ZDD->new($bdd->variables, max_nodes => $self->{max_nodes});
    my %result = (0 => 0, 1 => 1);
    for my $id (@{$bdd->reachable($self->{root})}) {
        next if $id < 2;
        my ($rank, $low, $high) = @{$bdd->node($id)};
        my $with = $zdd->mk($rank, 0, $result{$high});
        $result{$id} = $zdd->minimal($zdd->union($result{$low}, $with));
    }
    return {zdd => $zdd, root => $result{$self->{root}}, count => $zdd->count($result{$self->{root}})->bstr};
}

sub positive_sets {
    my ($self, %options) = @_;
    my $family = $self->minimal_positive;
    return $family->{zdd}->sets($family->{root}, %options);
}

sub prime_family {
    my ($self) = @_;
    my $bdd = $self->{bdd};
    my $variables = $bdd->variables;
    die "signed implicant variable limit exceeded\n" if @$variables > 256;
    my @literals;
    my %decode;
    for my $i (0 .. $#$variables) {
        for my $value (0, 1) {
            my $literal = 'lit_' . $i . '_' . $value;
            push @literals, $literal;
            $decode{$literal} = [$variables->[$i], $value];
        }
    }
    my $zdd = Skein::ZDD->new(\@literals, max_nodes => $self->{max_nodes});
    my %memo = (0 => 0, 1 => 1);
    my $calls = 0;
    my $walk;
    $walk = sub {
        my ($root) = @_;
        die "prime implicant work limit exceeded\n" if ++$calls > $self->{max_calls};
        return $memo{$root} if exists $memo{$root};
        my ($rank, $low, $high) = @{$bdd->node($root)};
        my $low_primes = $walk->($low);
        my $high_primes = $walk->($high);
        my $common = $walk->($bdd->apply('and', $low, $high));
        my $negative = $zdd->mk(2 * $rank, 0, $low_primes);
        my $positive = $zdd->mk(2 * $rank + 1, 0, $high_primes);
        my $family = $zdd->union($zdd->union($negative, $positive), $common);
        $memo{$root} = $zdd->minimal($family);
        return $memo{$root};
    };
    my $root = $walk->($self->{root});
    return {zdd => $zdd, root => $root, decode => \%decode, count => $zdd->count($root)->bstr, calls => $calls};
}

sub prime_implicants {
    my ($self, %options) = @_;
    my $family = $self->prime_family;
    my $sets = $family->{zdd}->sets($family->{root}, %options);
    return [map {
        my %cube;
        for my $literal (@$_) {
            my ($name, $value) = @{$family->{decode}{$literal}};
            die "inconsistent prime implicant\n" if exists($cube{$name}) && $cube{$name} != $value;
            $cube{$name} = $value;
        }
        \%cube;
    } @$sets];
}

sub verify_implicant {
    my ($self, $cube) = @_;
    return 0 unless restrict($self->{bdd}, $self->{root}, $cube) == 1;
    for my $name (keys %$cube) {
        my %smaller = %$cube;
        delete $smaller{$name};
        return 0 if restrict($self->{bdd}, $self->{root}, \%smaller) == 1;
    }
    return 1;
}

sub cube_mass {
    my ($class, $cube, $priors) = @_;
    my $mass = one();
    for my $name (sort keys %$cube) {
        my $p = probability($priors->{$name});
        $mass = mul($mass, $cube->{$name} ? $p : complement($p));
    }
    return text($mass);
}

1;
