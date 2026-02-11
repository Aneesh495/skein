use strict;
use warnings;
use Test::More;
use Skein::Linear qw(identity multiply solve inverse determinant rank rref transpose add_matrix scale_matrix);
use Skein::Rat qw(text);

sub strings { return [map { [map { text($_) } @$_] } @{$_[0]}] }

my $a = [[2,1], [1,3]];
is_deeply([map { text($_) } @{solve($a, [1,2])}], ['1/5','3/5'], 'exact linear solve');
is(text(determinant($a)), '5', 'determinant');
is_deeply(strings(inverse($a)), [['3/5','-1/5'],['-1/5','2/5']], 'exact inverse');
is_deeply(strings(multiply($a,inverse($a))), strings(identity(2)), 'inverse identity');
is(rank([[1,2,3],[2,4,6]]), 1, 'rank deficient matrix');
is_deeply(strings(transpose([[1,2,3],[4,5,6]])), [['1','4'],['2','5'],['3','6']], 'rectangular transpose');
is_deeply(strings(add_matrix($a,scale_matrix($a,-1))), [['0','0'],['0','0']], 'matrix cancellation');
is(text(determinant([[0,2],[3,4]])), '-6', 'pivot swap sign');
ok(!eval { solve([[1,1],[2,2]], [1,3]); 1 }, 'inconsistent system rejected');
ok(!eval { solve([[1,1],[2,2]], [1,2]); 1 }, 'nonunique system rejected');
ok(!eval { inverse([[1,1],[2,2]]); 1 }, 'singular inverse rejected');
ok(!eval { multiply([[1,2]], [[1,2]]); 1 }, 'dimension mismatch rejected');
is(text(determinant([])), '1', 'empty determinant');
for my $n (2 .. 5) {
    my $hilbert = [map {
        my $i = $_;
        [map { '1/' . ($i + $_ + 1) } 0 .. $n-1];
    } 0 .. $n-1];
    is_deeply(strings(multiply($hilbert,inverse($hilbert))), strings(identity($n)), 'ill-conditioned Hilbert inverse stays exact');
}
done_testing;
