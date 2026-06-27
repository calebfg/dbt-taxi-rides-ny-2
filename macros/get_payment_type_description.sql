{#
    This macro returns the description of the payment_type
#}

{% macro get_payment_type_description(payment_type) %}

    case when {{ payment_type }} = 1 then 'Credit card'
         when {{ payment_type }} = 2 then 'Cash'
         when {{ payment_type }} = 3 then 'No charge'
         when {{ payment_type }} = 4 then 'Dispute'
         when {{ payment_type }} = 5 then 'Unknown'
         when {{ payment_type }} = 6 then 'Voided trip'
         else 'EMPTY'
    end

{% endmacro %}