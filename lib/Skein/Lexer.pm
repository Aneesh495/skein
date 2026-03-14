package Skein::Lexer;
use 5.020;
use strict;
use warnings;
use Skein::Util qw(integer);

sub new {
    my ($class, $source, %options) = @_;
    die "source must be a string\n" if !defined($source) || ref($source);
    my $max_chars = $options{max_chars} // 4_194_304;
    integer($max_chars, 'source limit', 1, 64_000_000);
    die "source exceeds character limit\n" if length($source) > $max_chars;
    return bless {
        source => $source,
        name => $options{name} // '<model>',
        position => 0,
        line => 1,
        column => 1,
        count => 0,
        max_tokens => integer($options{max_tokens} // 200_000, 'token limit', 1),
        buffered => undef,
    }, $class;
}

sub _consume {
    my ($self, $length) = @_;
    my $part = substr($self->{source}, $self->{position}, $length);
    my @lines = split /\n/, $part, -1;
    if (@lines > 1) {
        $self->{line} += @lines - 1;
        $self->{column} = 1 + length($lines[-1]);
    } else {
        $self->{column} += $length;
    }
    $self->{position} += $length;
    return $part;
}

sub error {
    my ($self, $message, $token) = @_;
    my $line = $token ? $token->{line} : $self->{line};
    my $column = $token ? $token->{column} : $self->{column};
    die "$self->{name}:$line:$column: $message\n";
}

sub _scan {
    my ($self) = @_;
    while ($self->{position} < length($self->{source})) {
        my $rest = substr($self->{source}, $self->{position});
        if ($rest =~ /\A([\x20\t\r\n]+)/) {
            $self->_consume(length($1));
            next;
        }
        if ($rest =~ /\A(\#[^\n]*)/) {
            $self->_consume(length($1));
            next;
        }
        last;
    }
    my %location = (
        line => $self->{line}, column => $self->{column},
        offset => $self->{position},
    );
    if ($self->{position} == length($self->{source})) {
        return { type => 'eof', value => '', %location };
    }
    $self->error('token limit exceeded') if ++$self->{count} > $self->{max_tokens};
    my $rest = substr($self->{source}, $self->{position});
    if ($rest =~ /\A([A-Za-z_][A-Za-z0-9_]*)/) {
        my $value = $self->_consume(length($1));
        $self->error('identifier exceeds length limit') if length($value) > 128;
        return { type => 'name', value => $value, %location };
    }
    if ($rest =~ /\A(\d+\/\d+|\d*\.\d+|\d+)/) {
        my $value = $self->_consume(length($1));
        $self->error('number exceeds length limit') if length($value) > 1024;
        return { type => 'number', value => $value, %location };
    }
    if (substr($rest, 0, 1) eq '"') {
        $self->_consume(1);
        my $value = '';
        while ($self->{position} < length($self->{source})) {
            my $char = $self->_consume(1);
            return { type => 'string', value => $value, %location } if $char eq '"';
            $self->error('newline in string', \%location) if $char eq "\n" || $char eq "\r";
            if ($char eq '\\') {
                $self->error('unterminated string escape', \%location)
                    if $self->{position} == length($self->{source});
                my $escape = $self->_consume(1);
                my %escapes = ('n' => "\n", 'r' => "\r", 't' => "\t", '"' => '"', '\\' => '\\');
                $self->error("unknown string escape '$escape'", \%location)
                    unless exists $escapes{$escape};
                $char = $escapes{$escape};
            }
            $value .= $char;
            $self->error('string exceeds length limit', \%location) if length($value) > 4096;
        }
        $self->error('unterminated string', \%location);
    }
    if ($rest =~ /\A(<->|->|[!&|^=~(),;\[\]])/) {
        my $value = $self->_consume(length($1));
        return { type => 'symbol', value => $value, %location };
    }
    my $char = substr($rest, 0, 1);
    $self->error(sprintf('unexpected character U+%04X', ord($char)));
}

sub peek {
    my ($self) = @_;
    $self->{buffered} //= $self->_scan;
    return { %{$self->{buffered}} };
}

sub next {
    my ($self) = @_;
    my $token = $self->peek;
    $self->{buffered} = undef;
    return $token;
}

sub accept {
    my ($self, $value) = @_;
    return undef unless $self->peek->{value} eq $value && $self->peek->{type} ne 'eof';
    return $self->next;
}

sub expect {
    my ($self, $value) = @_;
    my $token = $self->next;
    $self->error("expected '$value', found '$token->{value}'", $token)
        unless $token->{value} eq $value && $token->{type} ne 'eof';
    return $token;
}

sub expect_type {
    my ($self, $type) = @_;
    my $token = $self->next;
    $self->error("expected $type, found '$token->{value}'", $token)
        unless $token->{type} eq $type;
    return $token;
}

sub tokens {
    my ($self) = @_;
    my @tokens;
    while (1) {
        my $token = $self->next;
        push @tokens, $token;
        last if $token->{type} eq 'eof';
    }
    return \@tokens;
}

1;
