-- +goose Up

-- Fail loudly if any layer value in `tiles` has no
-- corresponding row in `layer_types`. Without this, the INSERT...SELECT
-- below would silently drop those rows via its inner join.
-- +goose StatementBegin
DO $$
DECLARE
    missing_count integer;
    missing_values text;
BEGIN
    SELECT count(*), string_agg(DISTINCT layer, ', ')
    INTO missing_count, missing_values
    FROM tiles
    WHERE layer NOT IN (SELECT name FROM layer_types);

    IF missing_count > 0 THEN
        RAISE EXCEPTION 'Migration aborted: % rows in tiles have layer values not present in layer_types: %',
            missing_count, missing_values;
    END IF;
END $$;
-- +goose StatementEnd

-- New table with reordered columns (largest alignment first) and
-- layer converted from varchar(50) to smallint FK.
CREATE TABLE tiles_new (
    created_at timestamp without time zone DEFAULT now(),
    x integer NOT NULL,
    y integer NOT NULL,
    z smallint NOT NULL,
    layer smallint NOT NULL REFERENCES layer_types(id),
    data bytea NOT NULL,
    CONSTRAINT tiles_new_x_check CHECK (x >= 0),
    CONSTRAINT tiles_new_y_check CHECK (y >= 0),
    CONSTRAINT tiles_new_z_check CHECK (z >= 0 AND z <= 30),
    PRIMARY KEY (z, x, y, layer)
);

-- Copy all data across, mapping the old varchar layer name to the
-- new layer_types.id via join.
INSERT INTO tiles_new (created_at, x, y, z, layer, data)
SELECT t.created_at, t.x, t.y, t.z, lt.id, t.data
FROM tiles t
JOIN layer_types lt ON lt.name = t.layer;

-- Safety check #2: row counts must match exactly before we destroy
-- the original table. If this fails, the whole transaction rolls
-- back and `tiles` is untouched.
-- +goose StatementBegin
DO $$
DECLARE
    old_count bigint;
    new_count bigint;
BEGIN
    SELECT count(*) INTO old_count FROM tiles;
    SELECT count(*) INTO new_count FROM tiles_new;

    IF old_count != new_count THEN
        RAISE EXCEPTION 'Migration aborted: row count mismatch. tiles=% tiles_new=%',
            old_count, new_count;
    END IF;
END $$;
-- +goose StatementEnd

-- Swap: drop the old table, promote the new one, restore expected names.
DROP TABLE tiles;
ALTER TABLE tiles_new RENAME TO tiles;
ALTER TABLE tiles RENAME CONSTRAINT tiles_new_pkey TO tiles_pkey;
ALTER TABLE tiles RENAME CONSTRAINT tiles_new_x_check TO tiles_x_check;
ALTER TABLE tiles RENAME CONSTRAINT tiles_new_y_check TO tiles_y_check;
ALTER TABLE tiles RENAME CONSTRAINT tiles_new_z_check TO tiles_z_check;

-- Fresh table has no planner statistics yet, don't wait for autovacuum.
ANALYZE tiles;

-- Restore documentation comments (lost when the old table was dropped).
COMMENT ON TABLE tiles IS 'Pre-generated vector tiles (MVT/PBF format)';
COMMENT ON COLUMN tiles.z IS 'Zoom level';
COMMENT ON COLUMN tiles.x IS 'Tile X coordinate';
COMMENT ON COLUMN tiles.y IS 'Tile Y coordinate';
COMMENT ON COLUMN tiles.layer IS 'FK to layer_types.id (was varchar layer name pre-migration)';
COMMENT ON COLUMN tiles.data IS 'Gzipped MVT binary data';

-- +goose Down
-- Rebuilding tiles back to the varchar(50) layer form, reversing the
-- column order and type change. This does NOT restore the dropped
-- idx_tiles_lookup duplicate index (intentionally — see notes).
CREATE TABLE tiles_old (
    z smallint NOT NULL,
    x integer NOT NULL,
    y integer NOT NULL,
    layer character varying(50) NOT NULL,
    data bytea NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    CONSTRAINT tiles_old_x_check CHECK (x >= 0),
    CONSTRAINT tiles_old_y_check CHECK (y >= 0),
    CONSTRAINT tiles_old_z_check CHECK (z >= 0 AND z <= 30),
    PRIMARY KEY (z, x, y, layer)
);

INSERT INTO tiles_old (z, x, y, layer, data, created_at)
SELECT t.z, t.x, t.y, lt.name, t.data, t.created_at
FROM tiles t
JOIN layer_types lt ON lt.id = t.layer;

DROP TABLE tiles;
ALTER TABLE tiles_old RENAME TO tiles;
ALTER TABLE tiles RENAME CONSTRAINT tiles_old_pkey TO tiles_pkey;
ALTER TABLE tiles RENAME CONSTRAINT tiles_old_x_check TO tiles_x_check;
ALTER TABLE tiles RENAME CONSTRAINT tiles_old_y_check TO tiles_y_check;
ALTER TABLE tiles RENAME CONSTRAINT tiles_old_z_check TO tiles_z_check;

ANALYZE tiles;