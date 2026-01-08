use strict;
use warnings;
use Test::More;
use Skein::Lexer;

my $lexer = Skein::Lexer->new("# model\nnoise power ~ 1/100;\nnode out = !power | ite(a, b, 0);", name => 'case.sk');
my $tokens = $lexer->tokens;
is($tokens->[0]{value}, 'noise', 'comments skipped');
is($tokens->[0]{line}, 2, 'source line');
is($tokens->[0]{column}, 1, 'source column');
is($tokens->[3]{value}, '1/100', 'rational is one token');
is($tokens->[-1]{type}, 'eof', 'end token');
is(Skein::Lexer->new('.01')->next->{value}, '.01', 'decimal');
is(Skein::Lexer->new('"a\\nb"')->next->{value}, "a\nb", 'string escape');
my $look = Skein::Lexer->new('x y');
is($look->peek->{value}, 'x', 'peek');
is($look->next->{value}, 'x', 'peek does not consume');
is($look->next->{value}, 'y', 'next');
for my $source ('@', '"unterminated', '"bad\\q"') {
    ok(!eval { Skein::Lexer->new($source)->tokens; 1 }, 'invalid source rejected');
}
ok(!eval { Skein::Lexer->new('a b', max_tokens => 1)->tokens; 1 }, 'token limit');
ok(!eval { Skein::Lexer->new('abcdef', max_chars => 2); 1 }, 'source limit');
done_testing;
