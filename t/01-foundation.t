use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Skein::Rat qw(rat probability add subr mul divr complement text decimal sum product);
use Skein::Util qw(write_json decode_json_file digest integer boolean combinations);

is(text(add('1/3', '1/6')), '1/2', 'addition is exact');
is(text(mul('100000000000000000001/3', '3')), '100000000000000000001', 'large integer');
is(text(divr('2/3', '4/7')), '7/6', 'division');
is(text(subr(0, '1/7')), '-1/7', 'negative result');
is(text(complement('0.125')), '7/8', 'decimal parsed exactly');
is(text(sum('1/7', '2/7', '4/7')), '1', 'sum');
is(text(product('1/2', '1/3', '1/4')), '1/24', 'product');
my $original = rat('1/3');
add($original, 1);
is(text($original), '1/3', 'arithmetic does not mutate operands');
for my $bad ('NaN', '1/0', 'inf', '1e5', {}, undef) {
    ok(!eval { rat($bad); 1 }, 'reject invalid rational');
}
for my $bad ('-1/10', '11/10') {
    ok(!eval { probability($bad); 1 }, 'reject invalid probability');
}
is(decimal('1/8'), '0.125', 'decimal display');
ok(!eval { divr(1, 0); 1 }, 'reject zero denominator');
is(integer(12, 'count', 0, 20), 12, 'validated integer');
ok(!eval { integer('1.2'); 1 }, 'reject fractional limit');
is(boolean(1), 1, 'boolean');
ok(!eval { boolean(2); 1 }, 'reject invalid boolean');
my $dir = tempdir(CLEANUP => 1);
write_json("$dir/result.json", { b => 2, a => [1, 'x'] });
is_deeply(decode_json_file("$dir/result.json"), { b => 2, a => [1, 'x'] }, 'JSON round trip');
is(digest({a => 1, b => 2}), digest({b => 2, a => 1}), 'canonical digest');
my @sets;
combinations([qw(a b c)], 2, sub { push @sets, $_[0] });
is_deeply(\@sets, [[qw(a b)], [qw(a c)], [qw(b c)]], 'combination iterator');
done_testing;
