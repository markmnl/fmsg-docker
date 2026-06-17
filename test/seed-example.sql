\connect fmsgid

INSERT INTO address (address_lower, address, display_name)
VALUES ('@bob@example.com', '@Bob@example.com', 'Bob')
ON CONFLICT (address_lower) DO UPDATE
SET address = EXCLUDED.address,
    display_name = EXCLUDED.display_name;

INSERT INTO address (address_lower, address, display_name)
VALUES ('@carol@example.com', '@Carol@example.com', 'Carol')
ON CONFLICT (address_lower) DO UPDATE
SET address = EXCLUDED.address,
    display_name = EXCLUDED.display_name;
