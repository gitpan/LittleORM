#!/usr/bin/perl

use strict;

package LittleORM::Model;

# Extend LittleORM::Model capabilities with filter support:

sub f
{
	return &filter( @_ );
}

sub _disambiguate_filter_args
{
	my ( $self, $args ) = @_;

	{
		my $argsno = scalar @{ $args };
		my $class = ( ref( $self ) or $self );
		my @disambiguated = ();

		my $i = 0;
		foreach my $arg ( @{ $args } )
		{
			if( blessed( $arg ) and $arg -> isa( 'LittleORM::Filter' ) )
			{
				unless( $i % 2 )
				{
					# this will wrk only with single column PKs

					if( my $attr_co_connect = &LittleORM::Filter::find_corresponding_fk_attr_between_models( $class,
															   $arg -> model() ) )
					{
						push @disambiguated, $attr_co_connect;
						$i ++;

					} elsif( my $rev_connect = &LittleORM::Filter::find_corresponding_fk_attr_between_models( $arg -> model(),
															    $class ) )
					{
						push @disambiguated, $class -> __find_primary_key() -> name();
						$arg -> returning( $rev_connect );
						$i ++;


					} else
					{
						assert( 0,
							sprintf( "Can not automatically connect %s and %s - do they have FK between?",
								 $class,
								 $arg -> model() ) );
					}
				}
			} elsif( blessed( $arg ) and $arg -> isa( 'LittleORM::Clause' ) )
			{
				unless( $i % 2 )
				{
					push @disambiguated, '_clause';
					$i ++;
				}
			}

			push @disambiguated, $arg;
			$i ++;
		}
		$args = \@disambiguated;
	}

	return $args;
}

sub filter
{
	my ( $self, @args ) = @_;

	my @filters = ();

	my @clauseargs = ( _where => '1=1' );

	my $class = ( ref( $self ) or $self );

	my $rv = LittleORM::Filter -> new( model => $class );

	@args = @{ $self -> _disambiguate_filter_args( \@args ) };
	assert( scalar @args % 2 == 0 );

	while( my $arg = shift @args )
	{
		my $val = shift @args;

		if( $arg eq '_return' )
		{
			assert( $self -> meta() -> find_attribute_by_name( $val ), sprintf( 'Incorrect %s attribute "%s" in return',
											    $class,
											    $val ) );
			$rv -> returning( $val ); 

		} elsif( blessed( $val ) and $val -> isa( 'LittleORM::Filter' ) )
		{
			map { $rv -> push_clause( $_, $val -> table_alias() ) } @{ $val -> clauses() };

			my $conn_sql = sprintf( "%s.%s=%s.%s",
						# $self -> _db_table(),
						$rv -> table_alias(),
						&LittleORM::Model::__get_db_field_name( $self -> meta() -> find_attribute_by_name( $arg ) ),
						# $val -> model() -> _db_table(),
						$val -> table_alias(),
						&LittleORM::Model::__get_db_field_name( $val -> model() -> meta() -> find_attribute_by_name( $val -> get_returning() ) ) );

			$rv -> push_clause( $self -> clause( cond => [ _where => $conn_sql ],
							     table_alias => $rv -> table_alias() ) );

		} elsif( blessed( $val ) and $val -> isa( 'LittleORM::Clause' ) )
		{
			$rv -> push_clause( $val );
		} else
		{
			push @clauseargs, ( $arg, $val );
		}

	}

	{
		my $clause = LittleORM::Clause -> new( model => $class,
						       cond => \@clauseargs,
						       table_alias => $rv -> table_alias() );

		$rv -> push_clause( $clause );
	}


	return $rv;
}


package LittleORM::Filter;

# Actual filter implementation:

use Moose;

has 'model' => ( is => 'rw', isa => 'Str', required => 1 );
has 'table_alias' => ( is => 'rw', isa => 'Str', default => \&get_uniq_alias_for_table );
has 'returning' => ( is => 'rw', isa => 'Maybe[Str]' ); # return column name for connecting with other filter
has 'clauses' => ( is => 'rw', isa => 'ArrayRef[LittleORM::Clause]', default => sub { [] } );

use Carp::Assert 'assert';
use List::MoreUtils 'uniq';

{
	my $counter = 0;

	sub get_uniq_alias_for_table
	{
		$counter ++;

		return "T" . $counter;
	}

}

sub push_clause
{
	my ( $self, $clause, $table_alias ) = @_;

	unless( $clause -> table_alias() )
	{

		unless( $table_alias )
		{
			$table_alias = $self -> table_alias();
		}


		# maybe clone here to preserve original clause obj ?

		my $copy = bless( { %{ $clause } }, ref $clause );
		$clause = $copy;

		$clause -> table_alias( $table_alias );
	}

	push @{ $self -> clauses() }, $clause;

	return $self -> clauses();
}

sub get_returning
{
	my $self = shift;

	my $rv = $self -> returning();

	unless( $rv )
	{
		assert( my $pk = $self -> model() -> __find_primary_key(),
			sprintf( 'Model %s must have PK or specify "returning" manually',
				 $self -> model() ) );
		$rv = $pk -> name();
	}

	return $rv;

}

sub translate_into_sql_clauses
{
	my $self = shift;


	my $clauses_number = scalar @{ $self -> clauses() };

	my @all_clauses_together = ();

	for( my $i = 0; $i < $clauses_number; $i ++ )
	{
		my $clause = $self -> clauses() -> [ $i ];

		push @all_clauses_together, $clause -> sql();

	}

	return @all_clauses_together;
}

sub all_tables_used_in_filter
{
	my $self = shift;

	my %rv = ();

	foreach my $c ( @{ $self -> clauses() } )
	{
		assert( $c -> table_alias(), 'Unknown clause origin' );
		$rv{ $c -> table_alias() } = $c -> model() -> _db_table();
	}

	return %rv;
}

sub get_many
{
	my $self = shift;

	return $self -> call_orm_method( 'get_many', @_ );
}

sub get
{
	my $self = shift;

	return $self -> call_orm_method( 'get', @_ );
}

sub count
{
	my $self = shift;

	return $self -> call_orm_method( 'count', @_ );
}

sub delete
{
	assert( 0, 'Delete is not supported in LittleORM::Filter. Just map { $_ -> delete() } at what get_many() returns.' );
}

sub call_orm_method
{
	my $self = shift;
	my $method = shift;

	my @args = @_;

	my %all = $self -> all_tables_used_in_filter();

	return $self -> model() -> $method( @args,
					    _table_alias => $self -> table_alias(),
					    _tables_to_select_from => [ map { sprintf( "%s %s", $all{ $_ }, $_ ) } keys %all ],
					    _where => join( ' AND ', $self -> translate_into_sql_clauses() ) );
}

sub find_corresponding_fk_attr_between_models
{
	my ( $model1, $model2 ) = @_;

	my $rv = undef;

DQoYV7htzKfc5YJC:
	foreach my $attr ( $model1 -> meta() -> get_all_attributes() )
	{
		if( my $fk = &LittleORM::Model::__descr_attr( $attr, 'foreign_key' ) )
		{
			if( $model2 eq $fk )
			{
				$rv = $attr -> name();
			}
		}
	}
	
	return $rv;
}

42;
