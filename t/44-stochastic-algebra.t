use strict;
use warnings;
use Test::More;
use Skein::RNG;
use Skein::Markov;
use Skein::Linear qw(inverse determinant multiply identity solve rank transpose);
use Skein::Rat qw(rat text add subr mul divr compare zero one);

my $rng=Skein::RNG->new('stochastic-algebra');
for my $trial (1 .. 40) {
    my $p=(1+$rng->integer(9)) . '/10';
    my $q=(1+$rng->integer(9)) . '/10';
    my $chain=Skein::Markov->new([qw(up down)],[[text(subr(1,$p)),$p],[$q,text(subr(1,$q))]]);
    my $stationary=$chain->stationary;
    is($stationary->{down},text(divr($p,add($p,$q))),"two-state stationary balance $trial");
    is($stationary->{up},text(divr($q,add($p,$q))),"complement stationary balance $trial");
    is($chain->hitting_times(['down'])->{expected_steps}{up},text(divr(1,$p)),"geometric hitting time $trial");
    my $first=$chain->first_passage(['down'],8);
    my $survival=one();
    for my $t (1 .. 8) {
        is($first->{times}[$t]{mass},text(mul($survival,$p)),"first-passage geometric mass $trial/$t");
        $survival=mul($survival,subr(1,$p));
    }
    is($first->{survival},text($survival),"geometric tail $trial");
    my $distribution=$chain->distribution(7,$stationary);
    is_deeply($distribution,$stationary,"stationary law is invariant under seven transitions $trial");
}
for my $trial (1 .. 30) {
    my $n=1+$rng->integer(4);
    my @lower;
    my @upper;
    my $expected_det=1;
    for my $i (0 .. $n-1) {
        my @l;
        my @u;
        for my $j (0 .. $n-1) {
            push @l,$j==$i?1:$j<$i?$rng->integer(7)-3:0;
            push @u,$j==$i?1+$rng->integer(4):$j>$i?$rng->integer(7)-3:0;
        }
        $expected_det *= $u[$i];
        push @lower,\@l;
        push @upper,\@u;
    }
    # Construct integer products with plain arithmetic, independently of the
    # exact matrix implementation whose inverse and determinant are tested.
    my @matrix;
    for my $i (0 .. $n-1) {
        my @row;
        for my $j (0 .. $n-1) {
            my $sum=0;
            $sum += $lower[$i][$_]*$upper[$_][$j] for 0 .. $n-1;
            push @row,$sum;
        }
        push @matrix,\@row;
    }
    my $inverse=inverse(\@matrix);
    is(text(determinant(\@matrix)),"$expected_det","integer triangular-product determinant $trial");
    my $product=multiply(\@matrix,$inverse);
    for my $i (0 .. $n-1) {
        for my $j (0 .. $n-1) {
            is(text($product->[$i][$j]),$i==$j?'1':'0',"exact inverse residual $trial/$i/$j");
        }
    }
    is(rank(\@matrix),$n,"full-rank construction $trial");
    is(text(determinant(transpose(\@matrix))),"$expected_det","determinant invariant under transpose $trial");
}
my $trap=Skein::Markov->new([qw(start goal trap)],[[0,'1/3','2/3'],[0,1,0],[0,0,1]]);
is($trap->hitting_probabilities(['goal'])->{start},'1/3','closed non-target class preserves nonarrival probability');
ok(!defined($trap->hitting_times(['goal'])->{expected_steps}{start}),'positive nonarrival probability makes unconditional time infinite');
eval { $trap->stationary };
like($@,qr/no unique solution/,'multiple stationary measures do not yield an arbitrary distribution');
done_testing;
