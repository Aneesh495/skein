use strict;
use warnings;
use Test::More;
use Skein::Generate;
use Skein::Parser;
use Skein::Model;
use Skein::Source;
use Skein::Expr qw(render evaluate simplify size);
use Skein::Util qw(canonical_json);

my $generator=Skein::Generate->new(seed=>'expression-roundtrip');
my @names=qw(a b c d);
for my $trial (1 .. 120) {
    my $expr=$generator->expression(\@names,3);
    my $printed=render($expr);
    my $parsed=Skein::Parser->parse_expression($printed);
    is(canonical_json($parsed),canonical_json($expr),"generated expression syntax round trip $trial");
    my $simplified=simplify($parsed);
    ok(size($simplified)<=size($parsed),"simplification never grows expression $trial");
    for my $mask (0 .. 15) {
        my %values=map { $names[$_] => (($mask>>$_)&1) } 0 .. 3;
        is(evaluate($simplified,\%values),evaluate($expr,\%values),"simplification truth preserved $trial/$mask");
    }
}
my $source=<<'MODEL';
model whitespace;
noise a ~ 1/3;
noise b ~ 1/4;
node first = a -> b;
node second = exactly(1, a, b);
query baseline = P(first & second) factual(a | b) do(first=1);
MODEL
my $model=Skein::Model->from_text($source);
for my $trial (1 .. 40) {
    # Insert comments and whitespace only at token boundaries. The lexer
    # itself supplies those boundaries, so multi-character operators survive.
    require Skein::Lexer;
    my $lexer=Skein::Lexer->new($source);
    my @tokens;
    while (1) {
        my $token=$lexer->next;
        last if $token->{type} eq 'eof';
        push @tokens,$token->{value};
    }
    my $mutated='';
    for my $token (@tokens) {
        $mutated .= $token;
        $mutated .= (" \n","\t",'  '," # boundary\n")[$generator->{rng}->integer(4)];
    }
    is(Skein::Model->from_text($mutated)->digest,$model->digest,"token-boundary whitespace and comments preserve model $trial");
}
my @bad=(
    ['node a = 1 -> ;','expression'],
    ['node a = atleast(3, 1, 0);','threshold'],
    ['node a = exactly(1/2, 1);','integer'],
    ['node a = 1 <-> <-> 0;','expression'],
    ['query q = P(1) observe(0);','clause'],
    ['noise bad-name ~ 1/2;','expected'],
    ['node x = (0 | 1));','expected'],
    ['node x = 1; garbage;','declaration'],
);
for my $case (@bad) {
    my $ok=eval { Skein::Model->from_text($case->[0],name=>'mutation.sk'); 1 };
    ok(!$ok,'malformed mutation rejected');
    like($@,qr/mutation\.sk:\d+:\d+:/,'malformed mutation retains source location');
}
done_testing;
