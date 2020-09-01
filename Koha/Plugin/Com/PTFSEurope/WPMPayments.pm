use utf8;

package Koha::Plugin::Com::PTFSEurope::WPMPayments;

=head1 Koha::Plugin::Com::PTFSEurope::WPMPayments;

Koha::Plugin::Com::PTFSEurope::WPMPayments

=cut

use Modern::Perl;

use base qw(Koha::Plugins::Base)
use version 0.77;

use C4::Context;
use C4::Auth;
use Koha::Account;
use Koha::Account::Lines;
use Koha::Patrons;

use XML::LibXML;
use Digest::MD5 qw(md5_hex);
use HTML::Entities;

## Here we set our plugin version
our $VERSION = "00.00.06";
our $debug   = 0;

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'WPM Online Payments Plugin',
    author          => 'Martin Renvoize',
    date_authored   => '2018-06-13',
    date_updated    => "2020-08-20",
    minimum_version => '17.11.00.000',
    maximum_version => '20.05.00.000',
    version         => $VERSION,
    description     => 'This plugin implements online payments using '
      . 'WPM Educations payments platform.',
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub _version_check {
    my ( $self, $minversion ) = @_;

    my $kohaversion = Koha::version();
    return ( version->parse($kohaversion) > version->parse($minversion) );
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    return $self->retrieve_data('enable_opac_payments') eq 'Yes';
}

=head2 opac_online_payment_begin

  Initiate online payment process

=cut

sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    $debug and warn "Inside opac_online_payment_begin for: " . caller . "\n";

    my $cgi    = $self->{'cgi'};
    my $schema = Koha::Database->new()->schema();

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_begin.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    # Get the borrower
    my $borrower_result = Koha::Patrons->find($borrowernumber);

    # Create a transaction
    my $dbh   = C4::Context->dbh;
    my $table = $self->get_qualified_table_name('wpm_transactions');
    my $sth = $dbh->prepare("INSERT INTO $table (`accountline_id`) VALUES (?)");
    $sth->execute(undef);

    my $transaction_id =
      $dbh->last_insert_id( undef, undef, qw(wpm_transactions transaction_id) );

    # Construct redirect URI
    my $redirect_url = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account-pay-return.pl" );
    $redirect_url->query_form(
        {
            payment_method => scalar $cgi->param('payment_method'),
            transaction_id => $transaction_id
        }
    );

    # Construct callback URI
    my $callback_url =
      URI->new( C4::Context->preference('OPACBaseURL')
          . $self->get_plugin_http_path()
          . "/callback.pl" );

    # Construct cancel URI
    my $cancel_url = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account.pl" );

    # Construct custom fields
    my %customfields;
    for my $i ( 1 .. 10 ) {
        $customfields{$i} = $self->retrieve_data("customfield$i");
        if ( $customfields{$i} =~ m/(.*)\[% borrower\.(.*) %\](.*)/ ) {
            my ( $pre, $variable, $post ) = ( $1, $2, $3 );
            $customfields{$i} = $pre . $borrower_result->$variable . $post;
        }
    }

    # Construct XML POST
    my $xml = XML::LibXML::Document->new( '1.0', 'utf-8' );
    my $root = $xml->createElement('wpmpaymentrequest');

    my @fields = (
        {
            name => 'clientid',
            value =>
              { value => $self->retrieve_data('WPMClientID'), cdata => 0 }
        },
        {
            name  => 'requesttype',
            value => { value => 1, cdata => 0 }
        },
        {
            name => 'pathwayid',
            value =>
              { value => $self->retrieve_data('WPMPathwayID'), cdata => 0 }
        },
        {
            name  => 'departmentid',
            value => {
                value => $self->retrieve_data('WPMDepartmentID'),
                cdata => 0
            }
        },
        { name => 'staffid', value => { value => undef, cdata => 0 } },
        {
            name  => 'customerid',
            value => { value => $borrowernumber, cdata => 0 }
        },
        {
            name  => 'title',
            value => { value => $borrower_result->title, cdata => 1 }
        },
        {
            name  => 'firstname',
            value => { value => $borrower_result->firstname, cdata => 1 }
        },
        {
            name  => 'middlename',
            value => { value => $borrower_result->othernames, cdata => 1 }
        },
        {
            name  => 'lastname',
            value => { value => $borrower_result->surname, cdata => 1 }
        },
        {
            name  => 'emailfrom',
            value => {
                value => C4::Context->preference('KohaAdminEmailAddress'),
                cdata => 1
            }
        },
        {
            name  => 'toemail',
            value => { value => $borrower_result->email, cdata => 1 }
        },
        { name => 'ccemail', value => { value => undef, cdata => 1 } },
        {
            name  => 'transactionreference',
            value => { value => $transaction_id, cdata => 1 }
        },
        {
            name  => 'redirecturl',
            value => { value => $redirect_url, cdata => 1 }
        },
        {
            name  => 'callbackurl',
            value => { value => $callback_url, cdata => 1 }
        },
        {
            name  => 'cancelurl',
            value => { value => $cancel_url, cdata => 1 }
        },
        {
            name  => 'billaddress1',
            value => { value => $borrower_result->streetnumber, cdata => 1 }
        },
        {
            name  => 'billaddress2',
            value => { value => $borrower_result->address, cdata => 1 }
        },
        {
            name  => 'billaddress3',
            value => { value => $borrower_result->address2, cdata => 1 }
        },
        {
            name  => 'billtown',
            value => { value => $borrower_result->city, cdata => 1 }
        },
        {
            name  => 'billcounty',
            value => { value => $borrower_result->state, cdata => 1 }
        },
        {
            name  => 'billpostcode',
            value => { value => $borrower_result->zipcode, cdata => 1 }
        },
        {
            name  => 'billcountry',
            value => { value => $borrower_result->country, cdata => 1 }
        },
        {
            name  => 'customfield1',
            value => { value => $customfields{1}, cdata => 1 }
        },
        {
            name  => 'customfield2',
            value => { value => $customfields{2}, cdata => 1 }
        },
        {
            name  => 'customfield3',
            value => { value => $customfields{3}, cdata => 1 }
        },
        {
            name  => 'customfield4',
            value => { value => $customfields{4}, cdata => 1 }
        },
        {
            name  => 'customfield5',
            value => { value => $customfields{5}, cdata => 1 }
        },
        {
            name  => 'customfield6',
            value => { value => $customfields{6}, cdata => 1 }
        },
        {
            name  => 'customfield7',
            value => { value => $customfields{7}, cdata => 1 }
        },
        {
            name  => 'customfield8',
            value => { value => $customfields{8}, cdata => 1 }
        },
        {
            name  => 'customfield9',
            value => { value => $customfields{9}, cdata => 1 }
        },
        {
            name  => 'customfield10',
            value => { value => $customfields{10}, cdata => 1 }
        }
    );

    # Build XML from structure
    for my $field (@fields) {
        my $tag   = $xml->createElement( $field->{name} );
        my $value = $field->{value};
        if ( defined( $value->{'value'} ) && $value->{'value'} ne '' ) {
            if ( $value->{'cdata'} ) {
                my $data = XML::LibXML::CDATASection->new("$value->{'value'}");
                $tag->appendChild($data);
            }
            else {
                $tag->appendTextNode( $value->{'value'} );
            }
        }
        $root->appendChild($tag);
    }

    # Retrieve default field values
    my $DefaultVATDesc = $self->retrieve_data('DefaultVATDesc');
    my $DefaultVATCode = $self->retrieve_data('DefaultVATCode');
    my $DefaultVATRate = $self->retrieve_data('DefaultVATRate');

    # Add the accountlines to pay off
    my @accountline_ids = $cgi->multi_param('accountline');
    $debug
      and warn "Adding accountlines to transaction: "
      . join( ', ', @accountline_ids );
    my $accountlines = $schema->resultset('Accountline')
      ->search( { accountlines_id => \@accountline_ids } );
    my $now               = DateTime->now;
    my $dateoftransaction = $now->ymd('-') . ' ' . $now->hms(':');

    my $sum = 0;
    for my $accountline ( $accountlines->all ) {

        # Track sum
        my $amount = sprintf "%.2f", $accountline->amountoutstanding;
        $sum = $sum + $amount;

        # Build payments block
        ######################
        my $payments = $xml->createElement('payments');
        $payments->setAttribute( 'id'        => $accountline->accountlines_id );
        $payments->setAttribute( 'type'      => 'PN' );
        $payments->setAttribute(
            'payoption' => $self->_version_check('19.11.00')
            ? $accountline->debit_type_code
            : $accountline->accounttype );

        my $description = $xml->createElement("description");
        if ( defined( $accountline->description )
            && $accountline->description ne '' )
        {
            my $data_description = $accountline->description;
            my $data =
              XML::LibXML::CDATASection->new(
                encode_entities($data_description) );
            $description->appendChild($data);
        }
        $payments->appendChild($description);

        # Build payment block
        my $payment = $xml->createElement("payment");
        $payment->setAttribute( 'payid' => $accountline->accountlines_id );

        my $custom1 = $self->retrieve_data('payment_customfield1');
        if ($custom1) {
            my $customfield1 = $xml->createElement("customfield1");
            $customfield1->appendTextNode($custom1);
            $payment->appendChild($customfield1);
        }

        my $amounttopay = $xml->createElement("amounttopay");
        $amounttopay->appendTextNode($amount);
        $payment->appendChild($amounttopay);

        my $amounttopayvat = $xml->createElement("amounttopayvat");
        $amounttopayvat->appendTextNode('0');
        $payment->appendChild($amounttopayvat);

        my $amounttopayexvat = $xml->createElement("amounttopayexvat");
        $amounttopayexvat->appendTextNode($amount);
        $payment->appendChild($amounttopayexvat);

        my $vatdesc = $xml->createElement("vatdesc");
        $vatdesc->appendTextNode($DefaultVATDesc);
        $payment->appendChild($vatdesc);

        my $vatcode = $xml->createElement("vatcode");
        $vatcode->appendTextNode($DefaultVATCode);
        $payment->appendChild($vatcode);

        my $vatrate = $xml->createElement("vatrate");
        $vatrate->appendTextNode($DefaultVATRate);
        $payment->appendChild($vatrate);

        my $dateofpayment = $xml->createElement("dateofpayment");
        $dateofpayment->appendTextNode($dateoftransaction);
        $payment->appendChild($dateofpayment);

        my $editable = $xml->createElement("editable");
        $editable->setAttribute( 'minamount' => "0" );
        $editable->setAttribute( 'maxamount' => "0" );
        $editable->appendTextNode(0);
        $payment->appendChild($editable);

        my $mandatory = $xml->createElement("mandatory");
        $mandatory->appendTextNode(1);
        $payment->appendChild($mandatory);

        # Add 'payment' to 'payments' block
        $payments->appendChild($payment);

        # Add 'payments' to 'root' block
        $root->appendChild($payments);
    }

    # Add signature to xml
    $sum = sprintf "%.2f", $sum;
    $debug and warn "Total to pay" . $sum;
    my $msgid =
      md5_hex( $self->retrieve_data('WPMClientID')
          . $transaction_id
          . $sum
          . $self->retrieve_data('WPMSecret') );
    $root->setAttribute( 'msgid' => "$msgid" );

    # Finalise XML Document
    $xml->setDocumentElement($root);
    my $string = $xml->toString();

    $template->param(
        WPMPathway => $self->retrieve_data('WPMPathway'),
        XMLPost    => $string
    );

    print $cgi->header();
    print $template->output();
}

=head2 opac_online_payment_end

  Complete online payment process

=cut

sub opac_online_payment_end {
    my ( $self, $args ) = @_;

    $debug and warn "Inside opac_online_payment_end for: " . caller . "\n";
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my $transaction_id = $cgi->param('transaction_id');

    # Check payment went through here
    my $table = $self->get_qualified_table_name('wpm_transactions');
    my $dbh   = C4::Context->dbh;
    my $sth   = $dbh->prepare(
        "SELECT accountline_id FROM $table WHERE transaction_id = ?");
    $sth->execute($transaction_id);
    my ($accountline_id) = $sth->fetchrow_array();

    my $line =
      Koha::Account::Lines->find( { accountlines_id => $accountline_id } );
    my $transaction_value = $line->amount;
    my $transaction_amount = sprintf "%.2f", $transaction_value;
    $transaction_amount =~ s/^-//g;

    if ( defined($transaction_value) ) {
        $template->param(
            borrower      => scalar Koha::Patrons->find($borrowernumber),
            message       => 'valid_payment',
            message_value => $transaction_amount
        );
    }
    else {
        $template->param(
            borrower => scalar Koha::Patrons->find($borrowernumber),
            message  => 'no_amount'
        );
    }

    print $cgi->header();
    print $template->output();
}

## If your plugin needs to add some javascript in the OPAC, you'll want
## to return that javascript here. Don't forget to wrap your javascript in
## <script> tags. By not adding them automatically for you, you'll have a
## chance to include other javascript files if necessary.
sub opac_js {
    my ($self) = @_;

    # We could add in a preference driven 'enforced pay all' option here.
    return q|
        <script></script>
    |;
}

## If your tool is complicated enough to needs it's own setting/configuration
## you will want to add a 'configure' method to your plugin like so.
## Here I am throwing all the logic into the 'configure' method, but it could
## be split up like the 'report' method is.
sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments =>
              $self->retrieve_data('enable_opac_payments'),
            WPMClientID     => $self->retrieve_data('WPMClientID'),
            WPMSecret       => $self->retrieve_data('WPMSecret'),
            WPMPathway      => $self->retrieve_data('WPMPathway'),
            WPMPathwayID    => $self->retrieve_data('WPMPathwayID'),
            WPMDepartmentID => $self->retrieve_data('WPMDepartmentID'),
            DefaultVATDesc  => $self->retrieve_data('DefaultVATDesc'),
            DefaultVATCode  => $self->retrieve_data('DefaultVATCode'),
            DefaultVATRate  => $self->retrieve_data('DefaultVATRate'),
            customfield1    => $self->retrieve_data('customfield1'),
            customfield2    => $self->retrieve_data('customfield2'),
            customfield3    => $self->retrieve_data('customfield3'),
            customfield4    => $self->retrieve_data('customfield4'),
            customfield5    => $self->retrieve_data('customfield5'),
            customfield6    => $self->retrieve_data('customfield6'),
            customfield7    => $self->retrieve_data('customfield7'),
            customfield8    => $self->retrieve_data('customfield8'),
            customfield9    => $self->retrieve_data('customfield9'),
            customfield10   => $self->retrieve_data('customfield10'),
            payment_customfield1 =>
              $self->retrieve_data('payment_customfield1'),
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        $self->store_data(
            {
                enable_opac_payments =>
                  scalar $cgi->param('enable_opac_payments'),
                WPMClientID     => scalar $cgi->param('WPMClientID'),
                WPMSecret       => scalar $cgi->param('WPMSecret'),
                WPMPathway      => scalar $cgi->param('WPMPathway'),
                WPMPathwayID    => scalar $cgi->param('WPMPathwayID'),
                WPMDepartmentID => scalar $cgi->param('WPMDepartmentID'),
                DefaultVATDesc  => scalar $cgi->param('DefaultVATDesc'),
                DefaultVATCode  => scalar $cgi->param('DefaultVATCode'),
                DefaultVATRate  => scalar $cgi->param('DefaultVATRate'),
                customfield1    => scalar $cgi->param('customfield1'),
                customfield2    => scalar $cgi->param('customfield2'),
                customfield3    => scalar $cgi->param('customfield3'),
                customfield4    => scalar $cgi->param('customfield4'),
                customfield5    => scalar $cgi->param('customfield5'),
                customfield6    => scalar $cgi->param('customfield6'),
                customfield7    => scalar $cgi->param('customfield7'),
                customfield8    => scalar $cgi->param('customfield8'),
                customfield9    => scalar $cgi->param('customfield9'),
                customfield10   => scalar $cgi->param('customfield10'),
                payment_customfield1 =>
                  scalar $cgi->param('payment_customfield1'),
                last_configured_by => C4::Context->userenv->{'number'},
            }
        );
        $self->go_home();
    }
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    $self->store_data(
        {
            DefaultVATDesc => 'Exempt',
            DefaultVATCode => 'E',
            DefaultVATRate => 0,
        }
    );

    my $table = $self->get_qualified_table_name('wpm_transactions');

    return C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS $table (
            `transaction_id` INT( 11 ) NOT NULL AUTO_INCREMENT,
            `accountline_id` INT( 11 ),
            `updated` TIMESTAMP,
            PRIMARY KEY (`transaction_id`)
        ) ENGINE = INNODB;
    " );
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
#sub upgrade {
#    my ( $self, $args ) = @_;
#
#    my $dt = dt_from_string();
#    $self->store_data(
#        { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );
#
#    return 1;
#}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
#sub uninstall() {
#    my ( $self, $args ) = @_;
#
#    my $table = $self->get_qualified_table_name('mytable');
#
#    return C4::Context->dbh->do("DROP TABLE $table");
#}

1;
