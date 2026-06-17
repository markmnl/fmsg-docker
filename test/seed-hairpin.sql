\connect fmsgid

INSERT INTO address (address_lower, address, display_name)
VALUES ('@alice@hairpin.local', '@ALICE@hairpin.local', 'Alice')
ON CONFLICT (address_lower) DO UPDATE
SET address = EXCLUDED.address,
    display_name = EXCLUDED.display_name;
