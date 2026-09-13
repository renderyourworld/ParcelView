-- +goose Up

-- Extensions
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;
COMMENT ON EXTENSION postgis IS 'PostGIS geometry and geography spatial types and functions';

-- Trigger functions
-- +goose StatementBegin
CREATE FUNCTION public.refresh_boundary_geojson() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Refresh full boundary GeoJSON
    IF NEW.boundary IS DISTINCT FROM OLD.boundary OR NEW.centroid IS DISTINCT FROM OLD.centroid THEN
        NEW.boundary_geojson := jsonb_build_object(
            'type', 'Feature',
            'geometry', ST_AsGeoJSON(NEW.boundary, 6)::jsonb,
            'properties', jsonb_build_object(
                'id', NEW.id,
                'name', NEW.name,
                'state', NEW.state,
                'population', NEW.population,
                'region', NEW.region,
                'acres', NEW.acres,
                'square_miles', NEW.square_miles,
                'gis_api_url', NEW.gis_api_url,
                'tax_api_url', NEW.tax_api_url,
                'centroid', ST_AsGeoJSON(NEW.centroid)::jsonb
            )
        );
    END IF;

    -- Refresh simplified boundary GeoJSON
    IF NEW.boundary_simplified IS DISTINCT FROM OLD.boundary_simplified OR NEW.centroid IS DISTINCT FROM OLD.centroid THEN
        NEW.boundary_simplified_geojson := jsonb_build_object(
            'type', 'Feature',
            'geometry', ST_AsGeoJSON(NEW.boundary_simplified, 6)::jsonb,
            'properties', jsonb_build_object(
                'id', NEW.id,
                'name', NEW.name,
                'state', NEW.state,
                'population', NEW.population,
                'region', NEW.region,
                'acres', NEW.acres,
                'square_miles', NEW.square_miles,
                'gis_api_url', NEW.gis_api_url,
                'tax_api_url', NEW.tax_api_url,
                'centroid', ST_AsGeoJSON(NEW.centroid)::jsonb
            )
        );
    END IF;

    RETURN NEW;
END;
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION public.refresh_parcel_search_coords() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.geometry IS NULL THEN
        NEW.search_lat := NULL;
        NEW.search_lng := NULL;
    ELSE
        NEW.search_lat := ST_Y(ST_Transform(ST_PointOnSurface(NEW.geometry), 4326));
        NEW.search_lng := ST_X(ST_Transform(ST_PointOnSurface(NEW.geometry), 4326));
    END IF;
    RETURN NEW;
END;
$$;
-- +goose StatementEnd

CREATE TABLE public.counties (
    id smallint NOT NULL,
    name character varying(50) NOT NULL,
    state character varying(2) DEFAULT 'GA'::character varying,
    gis_api_url text,
    tax_api_url text,
    boundary public.geometry(MultiPolygon,4326) NOT NULL,
    boundary_simplified public.geometry(MultiPolygon,4326),
    centroid public.geometry(Point,4326),
    bbox public.geometry(Polygon,4326),
    population bigint,
    region character varying(50),
    acres numeric,
    square_miles numeric,
    boundary_geojson jsonb,
    boundary_simplified_geojson jsonb,
    max_record_count integer DEFAULT 1000,
    is_government_window boolean DEFAULT false,
    tax_provider character varying(20)
);

CREATE SEQUENCE public.counties_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.counties_id_seq OWNED BY public.counties.id;

CREATE TABLE public.county_field_mappings (
    id bigint NOT NULL,
    county_id integer,
    source_field character varying(255) NOT NULL,
    target_column character varying(50) NOT NULL,
    transform text
);

CREATE SEQUENCE public.county_field_mappings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.county_field_mappings_id_seq OWNED BY public.county_field_mappings.id;

CREATE TABLE public.import_checkpoints (
    id integer NOT NULL,
    county_name character varying(50) NOT NULL,
    last_processed_id bigint DEFAULT 0,
    status character varying(20) DEFAULT 'RUNNING'::character varying,
    start_time timestamp without time zone,
    end_time timestamp without time zone,
    total_processed integer DEFAULT 0,
    total_failed integer DEFAULT 0,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    import_type character varying(20) NOT NULL
);

CREATE SEQUENCE public.import_checkpoints_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.import_checkpoints_id_seq OWNED BY public.import_checkpoints.id;

CREATE TABLE public.owner_group_members (
    parcel_id bigint NOT NULL,
    group_id bigint NOT NULL,
    match_confidence smallint DEFAULT 0 NOT NULL,
    match_band character varying(10) DEFAULT 'low'::character varying NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE public.owner_groups (
    id bigint NOT NULL,
    group_key text NOT NULL,
    key_type character varying(16) NOT NULL,
    canonical_owner_name text,
    canonical_owner_address text,
    is_po_box boolean DEFAULT false NOT NULL,
    member_count integer DEFAULT 0 NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE SEQUENCE public.owner_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.owner_groups_id_seq OWNED BY public.owner_groups.id;

CREATE TABLE public.parcel_class_codes (
    id smallint NOT NULL,
    county_id integer NOT NULL,
    code character varying(10) NOT NULL,
    description text NOT NULL,
    category character varying(20) NOT NULL,
    color character varying(7) DEFAULT '#888888'::character varying,
    is_residential boolean GENERATED ALWAYS AS (((category)::text = 'Residential'::text)) STORED
);

CREATE SEQUENCE public.parcel_class_codes_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.parcel_class_codes_id_seq OWNED BY public.parcel_class_codes.id;

CREATE TABLE public.parcel_search (
    parcel_id bigint NOT NULL,
    county_id integer NOT NULL,
    objectid bigint NOT NULL,
    site_address text,
    site_address_norm text,
    mailing_city text,
    mailing_zip5 character varying(5),
    mailing_zip4 character varying(4),
    display_address text,
    lat real NOT NULL,
    lng real NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE public.parcel_taxes (
    id bigint NOT NULL,
    county_id integer NOT NULL,
    parcel_id bigint NOT NULL,
    tax_year smallint NOT NULL,
    tax_amount numeric,
    appraised numeric(14,2),
    assessed numeric(14,2),
    millage numeric(8,6),
    payer_name text,
    bill_url text,
    building_value numeric,
    land_value numeric,
    due_date character varying(20),
    paid_date character varying(20),
    total_due numeric,
    back_taxes numeric,
    last_updated_date timestamp without time zone
);

CREATE SEQUENCE public.parcel_taxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.parcel_taxes_id_seq OWNED BY public.parcel_taxes.id;

CREATE TABLE public.parcels (
    id bigint NOT NULL,
    county_id integer NOT NULL,
    parcel_id character varying(50) NOT NULL,
    objectid bigint,
    site_address text,
    site_number text,
    owner_name text,
    owner_address text,
    acres double precision,
    classification character varying(255),
    tax_district character varying(255),
    geometry public.geometry(MultiPolygon,3857),
    last_sync timestamp without time zone,
    processed boolean,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    error_message text,
    search_lat real,
    search_lng real
);

CREATE SEQUENCE public.parcels_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.parcels_id_seq OWNED BY public.parcels.id;

CREATE TABLE public.tiles (
    z smallint NOT NULL,
    x integer NOT NULL,
    y integer NOT NULL,
    layer character varying(50) DEFAULT 'parcels'::character varying NOT NULL,
    data bytea NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    CONSTRAINT tiles_x_check CHECK ((x >= 0)),
    CONSTRAINT tiles_y_check CHECK ((y >= 0)),
    CONSTRAINT tiles_z_check CHECK (((z >= 0) AND (z <= 30)))
);

COMMENT ON TABLE public.tiles IS 'Pre-generated vector tiles (MVT/PBF format)';
COMMENT ON COLUMN public.tiles.z IS 'Zoom level';
COMMENT ON COLUMN public.tiles.x IS 'Tile X coordinate';
COMMENT ON COLUMN public.tiles.y IS 'Tile Y coordinate';
COMMENT ON COLUMN public.tiles.layer IS 'Layer name (parcels, counties, etc.)';
COMMENT ON COLUMN public.tiles.data IS 'Gzipped MVT binary data';

CREATE TABLE public.us_zip5_areas (
    zip5 character varying(5) NOT NULL,
    geom public.geometry(MultiPolygon,4326) NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE public.us_zip5_city_lookup (
    zip5 character varying(5) NOT NULL,
    city text NOT NULL,
    state character varying(2) DEFAULT 'GA'::character varying NOT NULL,
    is_preferred boolean DEFAULT false NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

ALTER TABLE ONLY public.counties ALTER COLUMN id SET DEFAULT nextval('public.counties_id_seq'::regclass);
ALTER TABLE ONLY public.county_field_mappings ALTER COLUMN id SET DEFAULT nextval('public.county_field_mappings_id_seq'::regclass);
ALTER TABLE ONLY public.import_checkpoints ALTER COLUMN id SET DEFAULT nextval('public.import_checkpoints_id_seq'::regclass);
ALTER TABLE ONLY public.owner_groups ALTER COLUMN id SET DEFAULT nextval('public.owner_groups_id_seq'::regclass);
ALTER TABLE ONLY public.parcel_class_codes ALTER COLUMN id SET DEFAULT nextval('public.parcel_class_codes_id_seq'::regclass);
ALTER TABLE ONLY public.parcel_taxes ALTER COLUMN id SET DEFAULT nextval('public.parcel_taxes_id_seq'::regclass);
ALTER TABLE ONLY public.parcels ALTER COLUMN id SET DEFAULT nextval('public.parcels_id_seq'::regclass);
ALTER TABLE ONLY public.counties
    ADD CONSTRAINT counties_name_key UNIQUE (name);
ALTER TABLE ONLY public.counties
    ADD CONSTRAINT counties_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.county_field_mappings
    ADD CONSTRAINT county_field_mappings_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.import_checkpoints
    ADD CONSTRAINT import_checkpoints_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.owner_group_members
    ADD CONSTRAINT owner_group_members_pkey PRIMARY KEY (parcel_id);
ALTER TABLE ONLY public.owner_groups
    ADD CONSTRAINT owner_groups_group_key_key UNIQUE (group_key);
ALTER TABLE ONLY public.owner_groups
    ADD CONSTRAINT owner_groups_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.parcel_class_codes
    ADD CONSTRAINT parcel_class_codes_county_id_code_key UNIQUE (county_id, code);
ALTER TABLE ONLY public.parcel_class_codes
    ADD CONSTRAINT parcel_class_codes_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.parcel_search
    ADD CONSTRAINT parcel_search_pkey PRIMARY KEY (parcel_id);
ALTER TABLE ONLY public.parcel_taxes
    ADD CONSTRAINT parcel_taxes_parcel_id_tax_year_key UNIQUE (parcel_id, tax_year);
ALTER TABLE ONLY public.parcel_taxes
    ADD CONSTRAINT parcel_taxes_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.parcels
    ADD CONSTRAINT parcels_county_id_objectid_key UNIQUE (county_id, objectid);
ALTER TABLE ONLY public.parcels
    ADD CONSTRAINT parcels_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.tiles
    ADD CONSTRAINT tiles_pkey PRIMARY KEY (z, x, y, layer);
ALTER TABLE ONLY public.us_zip5_areas
    ADD CONSTRAINT us_zip5_areas_pkey PRIMARY KEY (zip5);
ALTER TABLE ONLY public.us_zip5_city_lookup
    ADD CONSTRAINT us_zip5_city_lookup_pkey PRIMARY KEY (zip5, city, state);
CREATE INDEX idx_checkpoint_status ON public.import_checkpoints USING btree (status);
CREATE INDEX idx_counties_boundary ON public.counties USING gist (boundary);
CREATE INDEX idx_counties_boundary_simplified ON public.counties USING gist (boundary_simplified);
CREATE INDEX idx_counties_centroid ON public.counties USING gist (centroid);
CREATE UNIQUE INDEX idx_county_code ON public.parcel_class_codes USING btree (county_id, code);
CREATE UNIQUE INDEX idx_county_import ON public.import_checkpoints USING btree (county_name, import_type);
CREATE UNIQUE INDEX idx_county_target ON public.county_field_mappings USING btree (county_id, target_column);
CREATE INDEX idx_owner_group_members_confidence ON public.owner_group_members USING btree (group_id, match_confidence DESC);
CREATE INDEX idx_owner_group_members_group ON public.owner_group_members USING btree (group_id);
CREATE INDEX idx_owner_groups_key_type ON public.owner_groups USING btree (key_type);
CREATE INDEX idx_parcel_search_city_prefix ON public.parcel_search USING btree (lower(mailing_city) text_pattern_ops) WHERE ((mailing_city IS NOT NULL) AND (mailing_city <> ''::text));
CREATE INDEX idx_parcel_search_city_trgm ON public.parcel_search USING gin (lower(mailing_city) public.gin_trgm_ops) WHERE ((mailing_city IS NOT NULL) AND (mailing_city <> ''::text));
CREATE UNIQUE INDEX idx_parcel_search_county_objectid ON public.parcel_search USING btree (county_id, objectid);
CREATE INDEX idx_parcel_search_display_prefix ON public.parcel_search USING btree (lower(display_address) text_pattern_ops) WHERE ((display_address IS NOT NULL) AND (display_address <> ''::text));
CREATE INDEX idx_parcel_search_display_trgm ON public.parcel_search USING gin (lower(display_address) public.gin_trgm_ops) WHERE ((display_address IS NOT NULL) AND (display_address <> ''::text));
CREATE INDEX idx_parcel_search_site_norm_prefix ON public.parcel_search USING btree (lower(site_address_norm) text_pattern_ops) WHERE ((site_address_norm IS NOT NULL) AND (site_address_norm <> ''::text));
CREATE INDEX idx_parcel_search_site_norm_trgm ON public.parcel_search USING gin (lower(site_address_norm) public.gin_trgm_ops) WHERE ((site_address_norm IS NOT NULL) AND (site_address_norm <> ''::text));
CREATE INDEX idx_parcel_search_zip5 ON public.parcel_search USING btree (mailing_zip5) WHERE ((mailing_zip5 IS NOT NULL) AND ((mailing_zip5)::text <> ''::text));
CREATE INDEX idx_parcel_taxes_year ON public.parcel_taxes USING btree (parcel_id, tax_year DESC);
CREATE INDEX idx_parcels_county_parcel ON public.parcels USING btree (county_id, parcel_id);
CREATE INDEX idx_parcels_geometry ON public.parcels USING gist (geometry);
CREATE INDEX idx_parcels_owner_name_prefix_active ON public.parcels USING btree (lower(owner_name) text_pattern_ops) WHERE ((processed IS NULL) AND (objectid IS NOT NULL) AND (search_lat IS NOT NULL) AND (search_lng IS NOT NULL) AND (owner_name IS NOT NULL) AND (owner_name <> ''::text));
CREATE INDEX idx_parcels_owner_name_trgm_active ON public.parcels USING gin (lower(owner_name) public.gin_trgm_ops) WHERE ((processed IS NULL) AND (objectid IS NOT NULL) AND (search_lat IS NOT NULL) AND (search_lng IS NOT NULL) AND (owner_name IS NOT NULL) AND (owner_name <> ''::text));
CREATE UNIQUE INDEX idx_tax_year ON public.parcel_taxes USING btree (parcel_id, tax_year);
CREATE INDEX idx_tiles_lookup ON public.tiles USING btree (z, x, y, layer);
CREATE INDEX idx_us_zip5_areas_geom ON public.us_zip5_areas USING gist (geom);
CREATE INDEX idx_us_zip5_city_lookup_zip_state ON public.us_zip5_city_lookup USING btree (zip5, state, is_preferred DESC, city);
CREATE TRIGGER refresh_parcel_search_coords_trigger BEFORE INSERT OR UPDATE OF geometry ON public.parcels FOR EACH ROW EXECUTE FUNCTION public.refresh_parcel_search_coords();
CREATE TRIGGER trg_refresh_boundary_geojson BEFORE INSERT OR UPDATE OF boundary, centroid, name, state, population, region, acres, square_miles, gis_api_url, tax_api_url ON public.counties FOR EACH ROW EXECUTE FUNCTION public.refresh_boundary_geojson();
ALTER TABLE ONLY public.county_field_mappings
    ADD CONSTRAINT county_field_mappings_county_id_fkey FOREIGN KEY (county_id) REFERENCES public.counties(id);
ALTER TABLE ONLY public.owner_group_members
    ADD CONSTRAINT owner_group_members_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.owner_groups(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.owner_group_members
    ADD CONSTRAINT owner_group_members_parcel_id_fkey FOREIGN KEY (parcel_id) REFERENCES public.parcels(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.parcel_class_codes
    ADD CONSTRAINT parcel_class_codes_county_id_fkey FOREIGN KEY (county_id) REFERENCES public.counties(id);
ALTER TABLE ONLY public.parcel_search
    ADD CONSTRAINT parcel_search_county_id_fkey FOREIGN KEY (county_id) REFERENCES public.counties(id);
ALTER TABLE ONLY public.parcel_search
    ADD CONSTRAINT parcel_search_parcel_id_fkey FOREIGN KEY (parcel_id) REFERENCES public.parcels(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.parcel_taxes
    ADD CONSTRAINT parcel_taxes_county_id_fkey FOREIGN KEY (county_id) REFERENCES public.counties(id);
ALTER TABLE ONLY public.parcel_taxes
    ADD CONSTRAINT parcel_taxes_parcel_id_fkey FOREIGN KEY (parcel_id) REFERENCES public.parcels(id);
ALTER TABLE ONLY public.parcels
    ADD CONSTRAINT parcels_county_id_fkey FOREIGN KEY (county_id) REFERENCES public.counties(id);

-- +goose Down
-- Baseline migration — this represents the full schema as of the goose
-- migration reset. A full automated teardown isn't meaningful for a
-- baseline; if you ever need to reverse it, restore from a database
-- backup taken before this migration was applied instead.
SELECT 1;