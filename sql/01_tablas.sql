--
-- PostgreSQL database dump
--


-- Dumped from database version 18.6 (Ubuntu 18.6-0ubuntu0.26.04.1)
-- Dumped by pg_dump version 18.6 (Ubuntu 18.6-0ubuntu0.26.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: bitacora; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bitacora (
    id_bitacora integer NOT NULL,
    id_configuracion integer NOT NULL,
    id_usuario integer NOT NULL,
    id_estacion integer NOT NULL,
    valor_anterior text,
    valor_nuevo text,
    fecha_hora timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    id_registro text
);


ALTER TABLE public.bitacora OWNER TO postgres;

--
-- Name: bitacora_id_bitacora_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.bitacora ALTER COLUMN id_bitacora ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.bitacora_id_bitacora_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: columna_auditada; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.columna_auditada (
    id_columna integer NOT NULL,
    nombre_columna character varying(100) NOT NULL,
    id_tabla integer NOT NULL
);


ALTER TABLE public.columna_auditada OWNER TO postgres;

--
-- Name: columna_auditada_id_columna_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.columna_auditada ALTER COLUMN id_columna ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.columna_auditada_id_columna_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: configuracion_auditoria; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.configuracion_auditoria (
    id_configuracion integer NOT NULL,
    id_columna integer NOT NULL,
    id_evento integer NOT NULL,
    activo boolean DEFAULT true NOT NULL
);


ALTER TABLE public.configuracion_auditoria OWNER TO postgres;

--
-- Name: configuracion_auditoria_id_configuracion_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.configuracion_auditoria ALTER COLUMN id_configuracion ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.configuracion_auditoria_id_configuracion_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: estacion_trabajo; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.estacion_trabajo (
    id_estacion integer NOT NULL,
    nombre_estacion character varying(100) NOT NULL,
    direccion_ip character varying(45)
);


ALTER TABLE public.estacion_trabajo OWNER TO postgres;

--
-- Name: estacion_trabajo_id_estacion_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.estacion_trabajo ALTER COLUMN id_estacion ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.estacion_trabajo_id_estacion_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: evento_auditoria; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.evento_auditoria (
    id_evento integer NOT NULL,
    tipo_evento character varying(20) NOT NULL
);


ALTER TABLE public.evento_auditoria OWNER TO postgres;

--
-- Name: evento_auditoria_id_evento_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.evento_auditoria ALTER COLUMN id_evento ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.evento_auditoria_id_evento_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tabla_auditada; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tabla_auditada (
    id_tabla integer NOT NULL,
    nombre_tabla character varying(100) NOT NULL,
    estado boolean DEFAULT true NOT NULL
);


ALTER TABLE public.tabla_auditada OWNER TO postgres;

--
-- Name: tabla_auditada_id_tabla_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.tabla_auditada ALTER COLUMN id_tabla ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.tabla_auditada_id_tabla_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: usuario_auditado; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.usuario_auditado (
    id_usuario integer NOT NULL,
    nombre_usuario character varying(100) NOT NULL
);


ALTER TABLE public.usuario_auditado OWNER TO postgres;

--
-- Name: usuario_auditado_id_usuario_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.usuario_auditado ALTER COLUMN id_usuario ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.usuario_auditado_id_usuario_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: bitacora bitacora_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bitacora
    ADD CONSTRAINT bitacora_pkey PRIMARY KEY (id_bitacora);


--
-- Name: columna_auditada columna_auditada_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.columna_auditada
    ADD CONSTRAINT columna_auditada_pkey PRIMARY KEY (id_columna);


--
-- Name: configuracion_auditoria configuracion_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.configuracion_auditoria
    ADD CONSTRAINT configuracion_auditoria_pkey PRIMARY KEY (id_configuracion);


--
-- Name: estacion_trabajo estacion_trabajo_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.estacion_trabajo
    ADD CONSTRAINT estacion_trabajo_pkey PRIMARY KEY (id_estacion);


--
-- Name: evento_auditoria evento_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.evento_auditoria
    ADD CONSTRAINT evento_auditoria_pkey PRIMARY KEY (id_evento);


--
-- Name: tabla_auditada tabla_auditada_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tabla_auditada
    ADD CONSTRAINT tabla_auditada_pkey PRIMARY KEY (id_tabla);


--
-- Name: usuario_auditado usuario_auditado_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.usuario_auditado
    ADD CONSTRAINT usuario_auditado_pkey PRIMARY KEY (id_usuario);


--
-- Name: bitacora bitacora_id_configuracion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bitacora
    ADD CONSTRAINT bitacora_id_configuracion_fkey FOREIGN KEY (id_configuracion) REFERENCES public.configuracion_auditoria(id_configuracion);


--
-- Name: bitacora bitacora_id_estacion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bitacora
    ADD CONSTRAINT bitacora_id_estacion_fkey FOREIGN KEY (id_estacion) REFERENCES public.estacion_trabajo(id_estacion);


--
-- Name: bitacora bitacora_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bitacora
    ADD CONSTRAINT bitacora_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario_auditado(id_usuario);


--
-- Name: columna_auditada columna_auditada_id_tabla_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.columna_auditada
    ADD CONSTRAINT columna_auditada_id_tabla_fkey FOREIGN KEY (id_tabla) REFERENCES public.tabla_auditada(id_tabla);


--
-- Name: configuracion_auditoria configuracion_auditoria_id_columna_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.configuracion_auditoria
    ADD CONSTRAINT configuracion_auditoria_id_columna_fkey FOREIGN KEY (id_columna) REFERENCES public.columna_auditada(id_columna);


--
-- Name: configuracion_auditoria configuracion_auditoria_id_evento_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.configuracion_auditoria
    ADD CONSTRAINT configuracion_auditoria_id_evento_fkey FOREIGN KEY (id_evento) REFERENCES public.evento_auditoria(id_evento);


--
-- PostgreSQL database dump complete
--


