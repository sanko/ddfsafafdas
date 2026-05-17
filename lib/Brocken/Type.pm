package Brocken::Type {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    my %TYPE_INFO = (

        # Abstract C types (platform-dependent)
        'void'      => { name => 'void',      size => 0, align => 0, is_void => 1 },
        'bool'      => { name => 'bool',      size => 1, align => 1 },
        'char'      => { name => 'char',      size => 1, align => 1 },
        'uchar'     => { name => 'uchar',     size => 1, align => 1, unsigned => 1 },
        'short'     => { name => 'short',     size => 2, align => 2 },
        'ushort'    => { name => 'ushort',    size => 2, align => 2, unsigned => 1 },
        'int'       => { name => 'int',       size => 4, align => 4 },
        'uint'      => { name => 'uint',      size => 4, align => 4, unsigned => 1 },
        'long'      => { name => 'long',      size => 8, align => 8 },
        'ulong'     => { name => 'ulong',     size => 8, align => 8, unsigned => 1 },
        'longlong'  => { name => 'longlong',  size => 8, align => 8 },
        'ulonglong' => { name => 'ulonglong', size => 8, align => 8, unsigned => 1 },

        # Fixed-width types
        'sint8'   => { name => 'sint8',   size => 1,  align => 1 },
        'int8'    => { name => 'int8',    size => 1,  align => 1 },
        'uint8'   => { name => 'uint8',   size => 1,  align => 1, unsigned => 1 },
        'sint16'  => { name => 'sint16',  size => 2,  align => 2 },
        'int16'   => { name => 'int16',   size => 2,  align => 2 },
        'uint16'  => { name => 'uint16',  size => 2,  align => 2, unsigned => 1 },
        'sint32'  => { name => 'sint32',  size => 4,  align => 4 },
        'int32'   => { name => 'int32',   size => 4,  align => 4 },
        'uint32'  => { name => 'uint32',  size => 4,  align => 4, unsigned => 1 },
        'sint64'  => { name => 'sint64',  size => 8,  align => 8 },
        'int64'   => { name => 'int64',   size => 8,  align => 8 },
        'uint64'  => { name => 'uint64',  size => 8,  align => 8, unsigned => 1 },
        'sint128' => { name => 'sint128', size => 16, align => 16 },
        'int128'  => { name => 'int128',  size => 16, align => 16 },
        'uint128' => { name => 'uint128', size => 16, align => 16, unsigned => 1 },

        # Floating point
        'float'      => { name => 'float',      size => 4,  align => 4,  is_float => 1 },
        'half'       => { name => 'half',       size => 2,  align => 2,  is_float => 1 },
        'float16'    => { name => 'float16',    size => 2,  align => 2,  is_float => 1 },
        'float32'    => { name => 'float32',    size => 4,  align => 4,  is_float => 1 },
        'double'     => { name => 'double',     size => 8,  align => 8,  is_float => 1 },
        'float64'    => { name => 'float64',    size => 8,  align => 8,  is_float => 1 },
        'longdouble' => { name => 'longdouble', size => 16, align => 16, is_float => 1 },

        # Special
        'string'  => { name => 'string',  size => 8, align => 8, is_pointer => 1 },
        'wstring' => { name => 'wstring', size => 8, align => 8, is_pointer => 1 },
        'sv'      => { name => 'sv',      size => 8, align => 8 },

        # Brocken native types
        'Int'    => { name => 'Int',    size => 8,  align => 8 },
        'String' => { name => 'String', size => 8,  align => 8, is_pointer => 1 },
        'Bool'   => { name => 'Bool',   size => 8,  align => 8 },
        'Any'    => { name => 'Any',    size => 16, align => 8 },
        'Class'  => { name => 'Class',  size => 8,  align => 8 },
        'Fiber'  => { name => 'Fiber',  size => 8,  align => 8 },
        'Array'  => { name => 'Array',  size => 8,  align => 8 },
    );

    sub new {
        my ( $class, $name ) = @_;
        my $info = $TYPE_INFO{$name} // { name => $name, size => 8, align => 8 };
        return bless $info, $class;
    }

    sub Pointer {
        my ($element_type) = @_;
        return bless { name => '*' . $element_type->{name}, size => 8, align => 8, is_pointer => 1, element_type => $element_type, }, __PACKAGE__;
    }

    sub Array {
        my ( $element_type, $count ) = @_;
        return bless {
            name         => '[' . $count . ':' . $element_type->{name} . ']',
            size         => $element_type->{size} * $count,
            align        => $element_type->{align},
            is_array     => 1,
            element_type => $element_type,
            array_count  => $count,
            },
            __PACKAGE__;
    }

    sub Struct {
        my ( $name, $fields ) = @_;
        my $size  = 0;
        my $align = 1;
        for my $f (@$fields) {
            my $field_align = $f->{type}{align};
            $size  = ( $size + $field_align - 1 ) & ~( $field_align - 1 );
            $align = $align > $field_align ? $align : $field_align;
        }
        $size = ( $size + $align - 1 ) & ~( $align - 1 );
        my $name_str = $name // '{' . join( ',', map { $_->{name} } @$fields ) . '}';
        return bless { name => $name_str, size => $size, align => $align, is_struct => 1, fields => $fields, }, __PACKAGE__;
    }

    sub Union {
        my ($variants) = @_;
        my $size       = 0;
        my $align      = 1;
        for my $v (@$variants) {
            $size  = $size > $v->{type}{size}   ? $size  : $v->{type}{size};
            $align = $align > $v->{type}{align} ? $align : $v->{type}{align};
        }
        my $name_str = '{' . join( '|', map { $_->{name} } @$variants ) . '}';
        return bless { name => $name_str, size => $size, align => $align, is_union => 1, variants => $variants, }, __PACKAGE__;
    }

    sub Callback {
        my ( $return_type, $arg_types ) = @_;
        my $sig = '(' . join( ',', map { $_->{name} } @$arg_types ) . ')->' . $return_type->{name};
        return bless { name => $sig, size => 8, align => 8, is_pointer => 1, return_type => $return_type, arg_types => $arg_types, }, __PACKAGE__;
    }

    sub Enum {
        my ( $base_type, $values ) = @_;
        return bless {
            name         => 'enum',
            size         => $base_type->{size},
            align        => $base_type->{align},
            is_enum      => 1,
            element_type => $base_type,
            variants     => $values,
            },
            __PACKAGE__;
    }
    sub is_numeric { my $self = shift; return $self->{size} > 0 && !$self->{is_pointer} && !$self->{is_struct}; }
    sub is_integer { my $self = shift; return $self->is_numeric && !$self->{is_float}; }
    sub is_signed  { my $self = shift; return $self->is_integer && ( $self->{name} !~ /^u/i ); }

    sub from_affix {
        my ($affix_type) = @_;
        my $name = ref($affix_type) ? $affix_type->type : $affix_type;
        return __PACKAGE__->new($name);
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Type - Type system mirroring Affix

=head1 SYNOPSIS

    use Brocken::Type;

    my $int_type = Brocken::Type->new('Int');
    my $ptr_type = Brocken::Type::Pointer($int_type);

=head1 DESCRIPTION

Provides a type system that mirrors the Affix FFI type system, supporting: - Primitive types (int, char, float, double,
etc.) - Fixed-width types (int8, uint16, int64, etc.) - Pointers, Arrays, Structs, Unions - Callback/function pointer
types - Enums

=cut
