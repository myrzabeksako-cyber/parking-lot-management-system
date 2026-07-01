--This package is the core “parking operations” module: it handles opening and closing tickets, calculating fees, customer balance, and subscription discounts
CREATE OR REPLACE PACKAGE pkg_parking_ops IS 
  FUNCTION fn_calc_ticket_fee (
    p_ticket_id IN parking_ticket.ticket_id%TYPE 
  ) RETURN NUMBER;

  FUNCTION fn_get_available_spot (
    p_lot_id       IN parking_lot.lot_id%TYPE,
    p_spot_type_id IN spot_type.spot_type_id%TYPE
  ) RETURN NUMBER;

  PROCEDURE pr_open_ticket (
    p_vehicle_id   IN  parking_ticket.vehicle_id%TYPE,
    p_lot_id       IN  parking_lot.lot_id%TYPE,
    p_spot_type_id IN  spot_type.spot_type_id%TYPE,
    p_tariff_id    IN  parking_ticket.tariff_id%TYPE,
    p_ticket_id    OUT parking_ticket.ticket_id%TYPE
  );

  PROCEDURE pr_close_ticket (
    p_ticket_id IN parking_ticket.ticket_id%TYPE
  );

  FUNCTION fn_customer_balance (
    p_customer_id IN customer.customer_id%TYPE
  ) RETURN NUMBER;

  PROCEDURE pr_change_subscription_discount (
    p_subscription_id IN subscription.subscription_id%TYPE,
    p_new_pct         IN subscription.discount_pct%TYPE
  );

END pkg_parking_ops;
/

CREATE OR REPLACE PACKAGE BODY pkg_parking_ops IS

  FUNCTION fn_calc_ticket_fee (
    p_ticket_id IN parking_ticket.ticket_id%TYPE
  ) RETURN NUMBER
  IS
    v_entry_time  parking_ticket.entry_time%TYPE;
    v_exit_time   parking_ticket.exit_time%TYPE;
    v_tariff_id   parking_ticket.tariff_id%TYPE;
    v_rate        tariff.rate_per_hour%TYPE;
    v_max_daily   tariff.max_daily%TYPE;
    v_hours       NUMBER;
    v_days        NUMBER;
    v_fee         NUMBER := 0;
  BEGIN
    SELECT entry_time, exit_time, tariff_id
    INTO   v_entry_time, v_exit_time, v_tariff_id
    FROM   parking_ticket
    WHERE  ticket_id = p_ticket_id;

    IF v_exit_time IS NULL THEN
      v_exit_time := SYSTIMESTAMP;
    END IF;

    SELECT rate_per_hour, max_daily
    INTO   v_rate, v_max_daily
    FROM   tariff
    WHERE  tariff_id = v_tariff_id;

    v_hours := (CAST(v_exit_time AS DATE) - CAST(v_entry_time AS DATE)) * 24;
    IF v_hours < 0 THEN
      v_hours := 0;
    END IF;

    v_days := CEIL(v_hours / 24);
    v_fee  := v_hours * v_rate;

    IF v_fee > v_max_daily * v_days THEN
      v_fee := v_max_daily * v_days;
    END IF;

    RETURN v_fee;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END fn_calc_ticket_fee;


  FUNCTION fn_get_available_spot (
    p_lot_id       IN parking_lot.lot_id%TYPE,
    p_spot_type_id IN spot_type.spot_type_id%TYPE
  ) RETURN NUMBER
  IS
    v_spot_id parking_spot.spot_id%TYPE;
  BEGIN
    SELECT s.spot_id
    INTO   v_spot_id
    FROM   parking_spot s
           JOIN parking_level l ON l.level_id = s.level_id
    WHERE  l.lot_id       = p_lot_id
    AND    s.spot_type_id = p_spot_type_id
    AND    s.status       = 'AVAILABLE'
    FETCH FIRST 1 ROWS ONLY;

    RETURN v_spot_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END fn_get_available_spot;


  PROCEDURE pr_open_ticket (
    p_vehicle_id   IN  parking_ticket.vehicle_id%TYPE,
    p_lot_id       IN  parking_lot.lot_id%TYPE,
    p_spot_type_id IN  spot_type.spot_type_id%TYPE,
    p_tariff_id    IN  parking_ticket.tariff_id%TYPE,
    p_ticket_id    OUT parking_ticket.ticket_id%TYPE
  )
  IS
    v_spot_id  parking_spot.spot_id%TYPE;
  BEGIN
    v_spot_id := fn_get_available_spot(p_lot_id, p_spot_type_id);

    IF v_spot_id IS NULL THEN
      RAISE_APPLICATION_ERROR(-20010, 'No available spot for given lot and type');
    END IF;


    SELECT NVL(MAX(ticket_id), 0) + 1
    INTO   p_ticket_id
    FROM   parking_ticket;

    INSERT INTO parking_ticket (
      ticket_id,
      vehicle_id,
      spot_id,
      entry_time,
      exit_time,
      status,
      tariff_id
    )
    VALUES (
      p_ticket_id,
      p_vehicle_id,
      v_spot_id,
      SYSTIMESTAMP,
      NULL,
      'OPEN',
      p_tariff_id
    );
  END pr_open_ticket;


  PROCEDURE pr_close_ticket (
    p_ticket_id IN parking_ticket.ticket_id%TYPE
  )
  IS
  BEGIN
    UPDATE parking_ticket
    SET    exit_time = SYSTIMESTAMP,
           status    = 'CLOSED'
    WHERE  ticket_id = p_ticket_id;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20011, 'Ticket not found');
    END IF;
  END pr_close_ticket;


  FUNCTION fn_customer_balance (
    p_customer_id IN customer.customer_id%TYPE
  ) RETURN NUMBER
  IS
    v_total_fee  NUMBER := 0;
    v_total_paid NUMBER := 0;
  BEGIN
    SELECT NVL(SUM(fn_calc_ticket_fee(t.ticket_id)), 0)
    INTO   v_total_fee
    FROM   parking_ticket t
           JOIN vehicle v ON v.vehicle_id = t.vehicle_id
    WHERE  v.customer_id = p_customer_id;

    SELECT NVL(SUM(p.amount), 0)
    INTO   v_total_paid
    FROM   parking_ticket t
           JOIN vehicle v ON v.vehicle_id = t.vehicle_id
           JOIN payment p ON p.ticket_id  = t.ticket_id
    WHERE  v.customer_id = p_customer_id
    AND    p.status = 'SUCCESS';

    RETURN v_total_fee - v_total_paid;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END fn_customer_balance;


  PROCEDURE pr_change_subscription_discount (
    p_subscription_id IN subscription.subscription_id%TYPE,
    p_new_pct         IN subscription.discount_pct%TYPE
  )
  IS
  BEGIN
    IF p_new_pct < 0 OR p_new_pct > 100 THEN
      RAISE_APPLICATION_ERROR(-20002, 'Discount must be between 0 and 100');
    END IF;

    UPDATE subscription
    SET    discount_pct = p_new_pct
    WHERE  subscription_id = p_subscription_id;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20001, 'Subscription not found');
    END IF;
  END pr_change_subscription_discount;

END pkg_parking_ops;
/

BEGIN
  DBMS_OUTPUT.PUT_LINE(
    'Fee for ticket 1 = ' || pkg_parking_ops.fn_calc_ticket_fee(1)
  );
END;
/

DECLARE
  v_spot_id NUMBER;
BEGIN
  v_spot_id := pkg_parking_ops.fn_get_available_spot(
                  p_lot_id       => 1,
                  p_spot_type_id => 30
               );
  DBMS_OUTPUT.PUT_LINE('Available spot = ' ||
                       NVL(TO_CHAR(v_spot_id), 'NONE'));
END;
/

DECLARE
  v_new_ticket_id  parking_ticket.ticket_id%TYPE;
BEGIN
  pkg_parking_ops.pr_open_ticket(
    p_vehicle_id   => 1,
    p_lot_id       => 9,
    p_spot_type_id => 67,
    p_tariff_id    => 1,
    p_ticket_id    => v_new_ticket_id
  );

  DBMS_OUTPUT.PUT_LINE('Opened ticket id = ' || v_new_ticket_id);
END;
/

BEGIN
  pkg_parking_ops.pr_close_ticket(p_ticket_id => 1);
  DBMS_OUTPUT.PUT_LINE('Ticket 1 closed');
END;
/

BEGIN
  DBMS_OUTPUT.PUT_LINE(
    'Balance for customer 1 = ' ||
    pkg_parking_ops.fn_customer_balance(1)
  );
END;
/

BEGIN
  pkg_parking_ops.pr_change_subscription_discount(
    p_subscription_id => 1,
    p_new_pct         => 15
  );
  DBMS_OUTPUT.PUT_LINE('Discount updated');
END;
/

SELECT discount_pct
FROM   subscription
WHERE  subscription_id = 1;

---------------------------------------------------------

--This package is a reporting module that prints different parking-related reports using DBMS_OUTPUT
CREATE OR REPLACE PACKAGE pkg_reports IS

  PROCEDURE pr_show_daily_revenue;

  PROCEDURE pr_show_lot_occupancy;

  PROCEDURE pr_show_expiring_subscriptions;

  PROCEDURE pr_show_customer_stats;

END pkg_reports;
/


CREATE OR REPLACE PACKAGE BODY pkg_reports IS

  PROCEDURE pr_show_daily_revenue IS
    CURSOR cur_daily_revenue IS
      SELECT TRUNC(payment_time) AS pay_date,
             SUM(amount)         AS total_amount
      FROM   payment
      WHERE  status = 'SUCCESS'
      GROUP  BY TRUNC(payment_time)
      ORDER  BY TRUNC(payment_time);

    r_day cur_daily_revenue%ROWTYPE;
  BEGIN
    OPEN cur_daily_revenue;
    LOOP
      FETCH cur_daily_revenue INTO r_day;
      EXIT WHEN cur_daily_revenue%NOTFOUND;

      DBMS_OUTPUT.PUT_LINE(
        'Date: ' || TO_CHAR(r_day.pay_date, 'YYYY-MM-DD') ||
        '  Revenue: ' || r_day.total_amount
      );
    END LOOP;

    CLOSE cur_daily_revenue;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Error in pr_show_daily_revenue: ' || SQLERRM);
  END pr_show_daily_revenue;


  PROCEDURE pr_show_lot_occupancy IS
    CURSOR cur_lot_occupancy IS
      SELECT pl.lot_id,
             l.lot_name,
             SUM(CASE WHEN s.status = 'AVAILABLE'      THEN 1 ELSE 0 END) AS cnt_available,
             SUM(CASE WHEN s.status = 'OCCUPIED'       THEN 1 ELSE 0 END) AS cnt_occupied,
             SUM(CASE WHEN s.status = 'RESERVED'       THEN 1 ELSE 0 END) AS cnt_reserved,
             SUM(CASE WHEN s.status = 'OUT_OF_SERVICE' THEN 1 ELSE 0 END) AS cnt_out_of_service
      FROM   parking_spot   s
             JOIN parking_level pl ON pl.level_id = s.level_id
             JOIN parking_lot   l  ON l.lot_id    = pl.lot_id
      GROUP  BY pl.lot_id, l.lot_name
      ORDER  BY pl.lot_id;

    r_occ cur_lot_occupancy%ROWTYPE;
  BEGIN
    OPEN cur_lot_occupancy;
    LOOP
      FETCH cur_lot_occupancy INTO r_occ;
      EXIT WHEN cur_lot_occupancy%NOTFOUND;

      DBMS_OUTPUT.PUT_LINE(
        'Lot ' || r_occ.lot_id || ' (' || r_occ.lot_name || '): ' ||
        'A=' || r_occ.cnt_available ||
        ', O=' || r_occ.cnt_occupied ||
        ', R=' || r_occ.cnt_reserved ||
        ', X=' || r_occ.cnt_out_of_service
      );
    END LOOP;

    CLOSE cur_lot_occupancy;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Error in pr_show_lot_occupancy: ' || SQLERRM);
  END pr_show_lot_occupancy;


  PROCEDURE pr_show_expiring_subscriptions IS
    CURSOR cur_expiring_subscriptions IS
      SELECT s.subscription_id,
             s.customer_id,
             s.spot_id,
             s.start_date,
             s.end_date,
             s.discount_pct
      FROM   subscription s
      WHERE  s.end_date BETWEEN TRUNC(SYSDATE) AND TRUNC(SYSDATE) + 30
      ORDER  BY s.end_date;

    r_sub cur_expiring_subscriptions%ROWTYPE;
  BEGIN
    OPEN cur_expiring_subscriptions;
    LOOP
      FETCH cur_expiring_subscriptions INTO r_sub;
      EXIT WHEN cur_expiring_subscriptions%NOTFOUND;

      DBMS_OUTPUT.PUT_LINE(
        'Sub ' || r_sub.subscription_id ||
        ' (cust=' || r_sub.customer_id ||
        ', spot=' || r_sub.spot_id || '): ' ||
        'ends ' || TO_CHAR(r_sub.end_date, 'YYYY-MM-DD') ||
        ', discount=' || r_sub.discount_pct
      );
    END LOOP;

    CLOSE cur_expiring_subscriptions;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Error in pr_show_expiring_subscriptions: ' || SQLERRM);
  END pr_show_expiring_subscriptions;


  PROCEDURE pr_show_customer_stats IS
    CURSOR cur_customer_stats IS
      SELECT c.customer_id,
             c.first_name,
             c.last_name,
             COUNT(DISTINCT v.vehicle_id) AS vehicle_count,
             NVL(SUM(
                 CASE WHEN p.status = 'SUCCESS' THEN p.amount END
             ), 0) AS total_paid
      FROM   customer c
             LEFT JOIN vehicle v        ON v.customer_id = c.customer_id
             LEFT JOIN parking_ticket t ON t.vehicle_id  = v.vehicle_id
             LEFT JOIN payment p        ON p.ticket_id   = t.ticket_id
      GROUP  BY c.customer_id, c.first_name, c.last_name
      ORDER  BY c.customer_id;

    r_cust cur_customer_stats%ROWTYPE;
  BEGIN
    OPEN cur_customer_stats;
    LOOP
      FETCH cur_customer_stats INTO r_cust;
      EXIT WHEN cur_customer_stats%NOTFOUND;

      DBMS_OUTPUT.PUT_LINE(
        'Customer ' || r_cust.customer_id || ' ' ||
        r_cust.first_name || ' ' || r_cust.last_name ||
        ': vehicles=' || r_cust.vehicle_count ||
        ', total_paid=' || r_cust.total_paid
      );
    END LOOP;

    CLOSE cur_customer_stats;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Error in pr_show_customer_stats: ' || SQLERRM);
  END pr_show_customer_stats;

END pkg_reports;
/


BEGIN
  pkg_reports.pr_show_daily_revenue;
END;
/


BEGIN
  pkg_reports.pr_show_daily_revenue;
  pkg_reports.pr_show_lot_occupancy;
  pkg_reports.pr_show_expiring_subscriptions;
  pkg_reports.pr_show_customer_stats;
END;
/

--This anonymous block automatically closes old open tickets
DECLARE
  CURSOR cur_old_open_tickets IS
    SELECT ticket_id,
           entry_time
    FROM   parking_ticket
    WHERE  status = 'OPEN'
    AND    entry_time < SYSTIMESTAMP - INTERVAL '24' HOUR
    ORDER  BY entry_time;

  r_ticket cur_old_open_tickets%ROWTYPE;

  v_closed_count NUMBER := 0;
BEGIN
  OPEN cur_old_open_tickets;
  LOOP
    FETCH cur_old_open_tickets INTO r_ticket;
    EXIT WHEN cur_old_open_tickets%NOTFOUND;


    UPDATE parking_ticket
    SET    exit_time = SYSTIMESTAMP,
           status    = 'CLOSED'
    WHERE  ticket_id = r_ticket.ticket_id;

    v_closed_count := v_closed_count + SQL%ROWCOUNT;

    DBMS_OUTPUT.PUT_LINE(
      'Closed old ticket ' || r_ticket.ticket_id ||
      ' (entry_time=' || TO_CHAR(r_ticket.entry_time, 'YYYY-MM-DD HH24:MI') || ')'
    );
  END LOOP;

  CLOSE cur_old_open_tickets;

  DBMS_OUTPUT.PUT_LINE('Total closed tickets: ' || v_closed_count);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Error in close-old-open-tickets block: ' || SQLERRM);
END;
/

--------------------------------------------------------------
--This package is responsible for billing: calculating how much a customer owes and registering payments
CREATE OR REPLACE PACKAGE pkg_billing IS

  FUNCTION fn_customer_balance (
    p_customer_id IN customer.customer_id%TYPE
  ) RETURN NUMBER;

  PROCEDURE pr_register_payment (
    p_ticket_id IN  payment.ticket_id%TYPE,
    p_amount    IN  payment.amount%TYPE,
    p_method    IN  payment.method%TYPE,
    p_pay_id    OUT payment.payment_id%TYPE
  );

END pkg_billing;
/

CREATE OR REPLACE PACKAGE BODY pkg_billing IS

  FUNCTION fn_customer_balance (
    p_customer_id IN customer.customer_id%TYPE
  ) RETURN NUMBER
  IS
    v_total_fee  NUMBER := 0;
    v_total_paid NUMBER := 0;
  BEGIN
    SELECT NVL(SUM(pkg_parking_ops.fn_calc_ticket_fee(t.ticket_id)), 0)
    INTO   v_total_fee
    FROM   parking_ticket t
           JOIN vehicle v ON v.vehicle_id = t.vehicle_id
    WHERE  v.customer_id = p_customer_id;

    SELECT NVL(SUM(p.amount), 0)
    INTO   v_total_paid
    FROM   parking_ticket t
           JOIN vehicle v ON v.vehicle_id = t.vehicle_id
           JOIN payment p ON p.ticket_id  = t.ticket_id
    WHERE  v.customer_id = p_customer_id
    AND    p.status = 'SUCCESS';

    RETURN v_total_fee - v_total_paid;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END fn_customer_balance;


  PROCEDURE pr_register_payment (
    p_ticket_id IN  payment.ticket_id%TYPE,
    p_amount    IN  payment.amount%TYPE,
    p_method    IN  payment.method%TYPE,
    p_pay_id    OUT payment.payment_id%TYPE
  )
  IS
    v_dummy NUMBER;
  BEGIN
    IF p_amount < 0 THEN
      RAISE_APPLICATION_ERROR(-20100, 'Amount must be >= 0');
    END IF;

    IF UPPER(p_method) NOT IN ('CASH','CARD','ONLINE') THEN
      RAISE_APPLICATION_ERROR(-20101, 'Invalid payment method');
    END IF;

    SELECT 1
    INTO   v_dummy
    FROM   parking_ticket
    WHERE  ticket_id = p_ticket_id;

    SELECT NVL(MAX(payment_id), 0) + 1
    INTO   p_pay_id
    FROM   payment;

    INSERT INTO payment (
      payment_id,
      ticket_id,
      amount,
      method,
      payment_time,
      status
    )
    VALUES (
      p_pay_id,
      p_ticket_id,
      p_amount,
      UPPER(p_method),
      SYSTIMESTAMP,
      'SUCCESS'
    );
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20102, 'Ticket not found for payment');
    WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(-20103,
        'Error in pr_register_payment: ' || SQLERRM);
  END pr_register_payment;

END pkg_billing;
/



BEGIN
DBMS_OUTPUT.PUT_LINE(
'Balance for customer 1 = ' ||
pkg_billing.fn_customer_balance(1)
);
END;
/


DECLARE
v_pay_id payment.payment_id%TYPE;
BEGIN
pkg_billing.pr_register_payment(
p_ticket_id => 1, 
p_amount => 50,
p_method => 'CARD',
p_pay_id => v_pay_id
);

DBMS_OUTPUT.PUT_LINE('Payment created, id = ' || v_pay_id);
END;
/
--------------------------------------------------------------------------
--This line defines a collection type.
CREATE OR REPLACE TYPE t_spot_list IS TABLE OF NUMBER;
/

--This procedure performs bulk reservation of parking spots for a customer using a list of spot IDs
CREATE OR REPLACE PROCEDURE pr_bulk_reserve_spots (
  p_customer_id IN customer.customer_id%TYPE,
  p_spots       IN t_spot_list
)
IS
  v_idx PLS_INTEGER;
BEGIN
  IF p_spots IS NULL OR p_spots.COUNT = 0 THEN
    RAISE_APPLICATION_ERROR(-20200, 'Spot list must not be empty');
  END IF;

  v_idx := p_spots.FIRST;
  WHILE v_idx IS NOT NULL LOOP
    BEGIN
      UPDATE parking_spot
      SET    status = 'RESERVED'
      WHERE  spot_id = p_spots(v_idx)
      AND    status  = 'AVAILABLE';

      IF SQL%ROWCOUNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE(
          'Spot ' || p_spots(v_idx) ||
          ' cannot be reserved (not AVAILABLE or not found)'
        );
      ELSE
        DBMS_OUTPUT.PUT_LINE(
          'Spot ' || p_spots(v_idx) || ' reserved'
        );
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE(
          'Error reserving spot ' || p_spots(v_idx) || ': ' || SQLERRM
        );
    END;

    v_idx := p_spots.NEXT(v_idx);
  END LOOP;
END;
/


DECLARE
  v_spots t_spot_list := t_spot_list(13, 35, 88); 
BEGIN
  pr_bulk_reserve_spots(
    p_customer_id => 1,
    p_spots       => v_spots
  );
END;
/
-------------------------------------------------------------
--This trigger automatically marks a parking spot as occupied when a new open ticket is inserted
CREATE OR REPLACE TRIGGER trg_ticket_ins_set_spot_occupied
AFTER INSERT ON parking_ticket
FOR EACH ROW
BEGIN
  IF :NEW.status = 'OPEN' THEN
    UPDATE parking_spot
    SET    status = 'OCCUPIED'
    WHERE  spot_id = :NEW.spot_id;
  END IF;
END;
/

--This anonymous block creates a new parking ticket with a generated id
DECLARE
  v_new_ticket_id NUMBER;
BEGIN
  SELECT NVL(MAX(ticket_id), 0) + 1
  INTO   v_new_ticket_id
  FROM   parking_ticket;

  INSERT INTO parking_ticket (
    ticket_id,
    vehicle_id,
    spot_id,
    entry_time,
    exit_time,
    status,
    tariff_id
  )
  VALUES (
    v_new_ticket_id,
    1,         
    12,       
    SYSTIMESTAMP,
    NULL,
    'OPEN',
    1           
  );
END;
/

--This trigger automatically frees a parking spot when a ticket is closed or cancelled
CREATE OR REPLACE TRIGGER trg_ticket_upd_free_spot
AFTER UPDATE OF status ON parking_ticket
FOR EACH ROW
BEGIN
  IF :NEW.status IN ('CLOSED', 'CANCELLED')
     AND :OLD.status = 'OPEN'
  THEN
    UPDATE parking_spot
    SET    status = 'AVAILABLE'
    WHERE  spot_id = :NEW.spot_id;
  END IF;
END;
/

SELECT ticket_id, spot_id
FROM   parking_ticket
WHERE  status = 'OPEN'
FETCH FIRST 1 ROWS ONLY;

--This trigger validates and normalizes payment data before insertion
CREATE OR REPLACE TRIGGER trg_payment_before_ins_chk
BEFORE INSERT ON payment
FOR EACH ROW
BEGIN
  IF :NEW.amount < 0 THEN
    RAISE_APPLICATION_ERROR(-20210, 'Amount must be >= 0');
  END IF;

  IF UPPER(:NEW.method) NOT IN ('CASH','CARD','ONLINE') THEN
    RAISE_APPLICATION_ERROR(-20211, 'Invalid payment method');
  END IF;

  IF :NEW.status IS NULL THEN
    :NEW.status := 'SUCCESS';
  END IF;
END;
/

--This trigger enforces basic validation rules for subscriptions
CREATE OR REPLACE TRIGGER trg_subscription_chk
BEFORE INSERT OR UPDATE ON subscription
FOR EACH ROW
BEGIN
  IF :NEW.discount_pct < 0 OR :NEW.discount_pct > 100 THEN
    RAISE_APPLICATION_ERROR(-20220, 'Discount must be between 0 and 100');
  END IF;

  IF :NEW.end_date <= :NEW.start_date THEN
    RAISE_APPLICATION_ERROR(-20221, 'End date must be after start date');
  END IF;
END;
/

--This statement creates an audit table for vehicle changes
CREATE TABLE vehicle_audit (
  audit_id      NUMBER GENERATED BY DEFAULT AS IDENTITY,
  vehicle_id    NUMBER,
  customer_id   NUMBER,
  plate_no      VARCHAR2(20),
  change_date   TIMESTAMP,
  operation     VARCHAR2(1)  
);

--This trigger writes an audit record whenever a vehicle is updated or deleted
CREATE OR REPLACE TRIGGER trg_vehicle_audit
BEFORE UPDATE OR DELETE ON vehicle
FOR EACH ROW
DECLARE
  v_op VARCHAR2(1);
BEGIN
  IF DELETING THEN
    v_op := 'D';
  ELSIF UPDATING THEN
    v_op := 'U';
  END IF;

  INSERT INTO vehicle_audit (
    vehicle_id,
    customer_id,
    plate_no,
    change_date,
    operation
  )
  VALUES (
    :OLD.vehicle_id,
    :OLD.customer_id,
    :OLD.plate_no,
    SYSTIMESTAMP,
    v_op
  );
END;
/

INSERT INTO vehicle_audit (
vehicle_id,
customer_id,
plate_no,
change_date,
operation
)
VALUES (
:OLD.vehicle_id,
:OLD.customer_id,
:OLD.plate_no,
SYSTIMESTAMP,
v_op
);
END;
/


DELETE FROM vehicle
WHERE vehicle_id = 65;

SELECT * FROM vehicle_audit
ORDER BY audit_id;







