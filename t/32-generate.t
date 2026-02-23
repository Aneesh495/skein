use strict;
use warnings;
use Test::More;
use Skein::Generate;
use Skein::Source;
use Skein::Engine;
use Skein::Oracle;

my $left = Skein::Generate->new(seed => 'regression');
my $right = Skein::Generate->new(seed => 'regression');
for my $i (0 .. 9) {
    my $a = $left->model(noise => $i % 5, nodes => 5);
    my $b = $right->model(noise => $i % 5, nodes => 5);
    is($a->digest, $b->digest, "case $i deterministic generation");
    is(Skein::Model->from_text(Skein::Source->emit($a))->digest, $a->digest, "case $i parseable source");
    is(Skein::Engine->new($a)->solve('baseline')->{probability},
        Skein::Oracle->new($a)->solve('baseline')->{probability}, "case $i independent outcome");
}
my $bad = eval { $left->model(noise => 13); 1 };
ok(!$bad, 'generator bound is enforced');
is(scalar @{$left->truth_table(3)}, 8, 'truth table size');
done_testing;
