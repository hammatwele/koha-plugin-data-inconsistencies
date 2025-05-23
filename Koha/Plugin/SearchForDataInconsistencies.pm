package Koha::Plugin::SearchForDataInconsistencies;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

#J'ajouter :

use Koha::Script;
use Koha::AuthorisedValues;
use Koha::Authorities;
use Koha::Biblios;
use Koha::BiblioFrameworks;
use Koha::Biblioitems;
use Koha::Items;
use Koha::ItemTypes;
use Koha::Patrons;
use Modern::Perl;
use strict;
use warnings;
use Encode qw(decode);
use Data::Dumper;
use CGI;
use utf8;
use DateTime;
use base qw(Koha::Plugins::Base);
use C4::Auth;
use C4::Context;

our $VERSION  = 1.4;
our $metadata = {
    name            => 'SearchForDataInconsistencies',
    author          => 'Phan Tung Bui, Olivier Vezina',
    description     => 'Check for data inconsistencies',
    date_authored   => '2024-01-12',
    date_updated    => '2024-12-10',
    minimum_version => '24.05',
    maximum_version => undef,
    version         => $VERSION,
};

our $dbh = C4::Context->dbh();
our $dir = C4::Context->config('intranetdir') . '/misc/maintenance/search_for_data_inconsistencies.pl';

my @result_presets = undef;


sub new {
    my ( $class, $args ) = @_;
    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    #bless $self,$class;
    return $self;
}

sub PageHome {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $locale = C4::Languages::getlanguage($cgi);

    if($locale eq "fr-CA" || $locale eq "fr"){
        @result_presets = (
            {
                id    => 'Exemplaires sans bibliothèque propriétaire ou dépositaire',
                title => "Vérification des exemplaires sans bibliothèque propriétaire ou dépositaire"
            },
            {
                id    => 'Autorité sans type valide',
                title => "Vérification des notices d'autorité sans type d'autorité valide"
            },
            {
                id    => 'Notices bibliographiques ou exemplaires avec un type de document non valide',
                title => "Vérification des notices bibliographiques et exemplaires sans type de document ou avec un type de document non valide"
            },
            {
                id    => 'Valeurs non valides dans les zones limitées à des valeurs autorisées',
                title => "Vérification des valeurs dans les zones limitées à des valeurs autorisées"
            },
            {
                id    => 'Notices bibliographiques sans titre',
                title => "Vérification des notices bibliographiques sans titre"
            },
            {
                id    => 'Utilisateurs trop jeunes ou trop âgés pour leur catégorie',
                title=> "Vérification des utilisateurs trop jeunes ou trop âgés pour leur catégorie"
            },
            {
                id    => 'Relation entre utilisateurs invalide',
                title => "Vérification pour des boucles de relations entre utilisateurs"
            }
        );
    }else{
       @result_presets = (
            {
                id    => 'Items without home or holding library',
                title => "Check for items without home or holding library",
            },
            {
                id    => 'Authority records with invalid authority type',
                title => "Check for authority records with invalid authority type",
            },
            {
                id    => 'Bibliographic records or items without an item type or with an invalid item type',
                title=> "Check for bibliographic records and items without an item type or with an invalid item type",
            },
            {
                id    => 'Invalid values in fields where the framework limits to an authorized value category',
                title => "Check for invalid values in fields where the framework limits to an authorized value category",
            },
            {
                id    => 'Repetition of Biblio without title in 245$a',
                title => "Check for bibliographic records without a title",
            },
            {
                id    => 'Patrons with invalid age for their category',
                title=> "Check for patrons who are too old or too young for their category",
            },
            {
                id    => 'Invalid guarantors relationships',
                title => "Check for relationships or dependencies between borrowers in a loop",
            }
        );
    }

    # Find locale-appropriate template
    my $template = undef;
    eval {
        $template =
          $self->get_template( { file => "home_" . $locale . ".tt" } );
    };
    if ( !$template ) {
        $locale = substr $locale, 0, 2;
        eval {
            $template = $self->get_template( { file => "home_$locale.tt" } );
        };
    }
    $template = $self->get_template( { file => 'home.tt' } ) unless $template;
    $template->param( result_presets => \@result_presets );
	print $cgi->header(-type => 'text/html',-charset => 'utf-8');
    print $template->output();
}

sub PageResult {
    my ( $self, $args ) = @_;
    my $cgi      = $self->{'cgi'};
    my $locale   = C4::Languages::getlanguage($cgi);
    my $template = undef;


    my %method_map;
    my $edit_item;
    my $edit_authority;
    my $edit_patron;
    my $edit_record;
    my $back_button;
    if($locale eq "fr-CA" || $locale eq "fr"){
        $edit_item="Modifier l'exemplaire #";
        $edit_authority="Modifier l'authorité #";
        $edit_patron="Modifier l'utilisateur #";
        $edit_record="Modifier la notice #";
        $back_button = "Retour";
        %method_map = (
            'Exemplaires sans bibliothèque propriétaire ou dépositaire'   => \&check_items_branch,
            'Autorité sans type valide' => \&check_items_auth_header,
            'Notices bibliographiques ou exemplaires avec un type de document non valide'   => \&check_items_status,
            'Valeurs non valides dans les zones limitées à des valeurs autorisées' => \&check_items_framework,
            'Notices bibliographiques sans titre'=> \&check_items_title,
            'Utilisateurs trop jeunes ou trop âgés pour leur catégorie' => \&check_age_for_category,
            'Relation entre utilisateurs invalide' => \&check_relationships,
        );
    } else{
        $edit_item="Edit item #";
        $edit_authority="Edit Authority #";
        $edit_patron="Edit patron #";
        $edit_record="Edit record #";
        $back_button="Back";
        %method_map = (
            'Items without home or holding library'    => \&check_items_branch,
            'Authority records with invalid authority type' => \&check_items_auth_header,
            'Bibliographic records or items without an item type or with an invalid item type'    => \&check_items_status,
            'Invalid values in fields where the framework limits to an authorized value category' => \&check_items_framework,
            'Repetition of Biblio without title in 245$a'     => \&check_items_title,
            'Patrons with invalid age for their category'    => \&check_age_for_category,
            'Invalid guarantors relationships'   => \&check_relationships,
        );
    }

    $template = $self->get_template( { file => 'result.tt' } ) unless $template;

    #For every checked preset, generate the appropriate message :
    my @main_messages;
    my @checkbox_preset = $cgi->multi_param('checkbox-preset');

    for my $key ( @checkbox_preset ) {
        if (exists $method_map{$key}) {
            my ($messages, $numbers) = $method_map{$key}->();  # Get messages and numbers from the method
            push @main_messages, {method_name => $key, messages => [map { decode('UTF-8', $_) } @$messages], numbers => $numbers};  # Store messages in UTF-8
        }
    }

    $template->param(
        main_messages => \@main_messages,
        edit_item => $edit_item,
        edit_authority => $edit_authority,
        edit_record => $edit_record,
        edit_patron => $edit_patron,
        back_button => $back_button,
     );
	print $cgi->header(-type => 'text/html',-charset => 'utf-8');
    print $template->output();

}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    if ( $cgi->param('action') ) {
        $self->PageResult();
    }
    else {
        $self->PageHome();
    }

}

sub check_items_branch {
    my @messages;
    my $output = `$dir --check-branch`;

    # Split the modified output into messages
    @messages = split /\n/, $output;
    # Extract numbers that contains itemnumber and biblionumber
    my @numbers;
    while ($output =~ /itemnumber=(\d+)\s+and\s+biblionumber=(\d+)/g) {
        push @numbers, [$1,$2];
    }

    return (\@messages, \@numbers);
}

sub check_items_auth_header {
    my @messages;
    my $output = `$dir --check-auth`;

    # Split the modified output into messages
    @messages = split /\n/, $output;

    # Extract numbers that contains itemnumber and biblionumber
    my @numbers;
    while ($output =~ /authid=(\d+)/g) {
        push @numbers, $1;
    }

    return (\@messages, \@numbers);

}

sub check_items_status {
    my @messages;
    my $output = `$dir --check-status`;

    # Split the modified output into messages
    @messages = split /\n/, $output;

    # Extract numbers that contains itemnumber and biblionumber
    my @numbers;
    foreach (@messages) {
        if($_ =~ /itemnumber=(\d+),\s+biblionumber=(\d+)/ or $_ =~ /itemnumber=(\d+)\s+and\s+biblionumber\s=\s(\d+)/) {
            push @numbers, [$1,$2];
        }
    }
    print STDERR "$output\n";
    foreach (@numbers) {
        print STDERR "$_\n";
    }
    return (\@messages, \@numbers);
}

sub check_items_framework {
    my @messages;
    my $output = `$dir --check-framework`;

    # Split the modified output into messages
    @messages = split /\n/, $output;

    # Extract numbers
    my @numbers;
    while ($output =~ /\{(\d+)\s+and\s+(\d+)\s+=>\s+\w+\}/g) {
        push @numbers, [$1,$2];
    }

    return (\@messages, \@numbers);
}

sub check_items_title {
    my @messages;
    my $output = `$dir --check-title`;

    # Split the modified output into messages
    @messages = split /\n/, $output;

    # Extract numbers
    my @numbers;
    while ($output =~ /biblionumber=(\d+)/g) {
        push @numbers, $1;
    }
    return (\@messages, \@numbers);
}

sub check_age_for_category {
    my @messages;
    my $output = `$dir --check-age`;

    # Split the modified output into messages
    @messages = split /\n/, $output;

    # Solely to differentiate numbers and borrowernumbers

    # Extract borrowernumbers
    my @numbers;
    while ($output =~ /borrowernumber=(\d+)/g) {
        push @numbers, $1;
    }
    return (\@messages,\@numbers);
}

sub check_relationships {
    my @messages;
    my $output = `$dir --check-loop`;

    # Split the modified output into messages
    @messages = split /\n/, $output;

    my @numbers;
    while ($output =~ /(?:borrowers id\s*:\s*|,\s*)(\d+)/g) {
        push @numbers, $1;
    }


    return (\@messages, \@numbers);
}
