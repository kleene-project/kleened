PORTNAME=		kleened
PORTVERSION=	0.0.1
DISTVERSIONPREFIX=	v
CATEGORIES=		sysutils

MAINTAINER=		lasse@philomath.dk
COMMENT=		Docker-inspired tool for container management in FreeBSD

LICENSE=		BSD2CLAUSE

BUILD_DEPENDS=	gmake:devel/gmake \
		mix:lang/elixir rebar3:devel/rebar3 \
	        ${LOCALBASE}/lib/elixir/lib/hex/ebin:devel/elixir-hex

#RUN_DEPENDS=	erlc:lang/erlang

USES=			ssl
USE_GITHUB=		yes
GH_TUPLE=		lgandersen:jocker:f45d0f4:DEFAULT
USE_RC_SUBR=	kleened

SUB_FILES=			pkg-message

MIX_TARGET=			release
ELIXIR_LOCALE=		en_US.UTF-8
ELIXIR_APP_NAME=	${PORTNAME}
MIX_ENV=			MIX_REBAR3=${LOCALBASE}/bin/rebar3 \
					LANG=${ELIXIR_LOCALE} \
					LC_ALL=${ELIXIR_LOCALE} \
					MIX_PATH=${LOCALBASE}/lib/elixir/lib/hex/ebin \
					MIX_HOME=${LOCALBASE}/bin/mix
MIX_ENV_NAME=		prod
MIX_CMD=			${LOCALBASE}/bin/mix
MIX_COMPILE=		${SETENV} ${MIX_ENV} MIX_ENV=${MIX_ENV_NAME} ${MIX_CMD} ${MIX_TARGET}

RELEASE_PATH=		${WRKSRC}/_build/prod/rel/kleened
RELEASE_BINARIES=	escript dialyzer erlexec beam.smp heart dyn_erl to_erl \
					erlc epmd run_erl typer inet_gethost erl_child_setup ct_run \
					erl_call yielding_c_fun

.include <bsd.port.pre.mk>

do-build:
	@cd ${WRKSRC} && ${MIX_COMPILE}

do-install:
	@${MKDIR} ${STAGEDIR}${PREFIX}/etc/kleened
	@${INSTALL_DATA} ${WRKSRC}/example/kleened_config.yaml \
		${STAGEDIR}${PREFIX}/etc/kleened/config.yaml.sample
	@${INSTALL_DATA} ${WRKSRC}/example/pf.conf.kleene \
		${STAGEDIR}${PREFIX}/etc/kleened/pf.conf.kleene.sample
	@${INSTALL_PROGRAM} ${WRKSRC}/priv/bin/kleened_pty \
		${STAGEDIR}${PREFIX}/bin/kleened_pty
	@${MKDIR} ${STAGEDIR}${PREFIX}/lib/kleened/bin
	@${INSTALL_SCRIPT} ${WRKSRC}/_build/prod/rel/kleened/bin/kleened \
		${STAGEDIR}${PREFIX}/lib/kleened/bin/
	@cd ${RELEASE_PATH}/lib && \
		${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/lib/kleened/lib
	@cd ${RELEASE_PATH} && ERTS_DIR=$$(${FIND} erts-* -depth 1 -type d) && \
		${COPYTREE_SHARE} ./$$ERTS_DIR ${STAGEDIR}${PREFIX}/lib/kleened/ && \
		${CHMOD} +x ${STAGEDIR}${PREFIX}/lib/kleened/$$ERTS_DIR/*
	@cd ${RELEASE_PATH}/releases && \
		${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/lib/kleened/releases
	@cd ${RELEASE_PATH}/releases && \
		${INSTALL_DATA} ${WRKSRC}/_build/prod/rel/kleened/releases/start_erl.data ${STAGEDIR}${PREFIX}/lib/kleened/releases/
	@${INSTALL_SCRIPT} ${RELEASE_PATH}/releases/0.0.1/elixir \
		${STAGEDIR}${PREFIX}/lib/kleened/releases/0.0.1/
	@${INSTALL_SCRIPT} ${RELEASE_PATH}/releases/0.0.1/iex \
		${STAGEDIR}${PREFIX}/lib/kleened/releases/0.0.1/
	@CRYPTO_DIR=$$(${FIND} ${STAGEDIR}${PREFIX}/lib/kleened/lib/crypto-* -depth 0) \
		&& ${STRIP_CMD} $$CRYPTO_DIR/priv/lib/*.so
	@ASN1_DIR=$$(${FIND} ${STAGEDIR}${PREFIX}/lib/kleened/lib/asn1-* -depth 0) \
		&& ${STRIP_CMD} $$ASN1_DIR/priv/lib/asn1rt_nif.so
	@${STRIP_CMD} ${STAGEDIR}${PREFIX}/lib/kleened/lib/exqlite-0.20.0/priv/sqlite3_nif.so
.for bin in ${RELEASE_BINARIES}
	@cd ${STAGEDIR}${PREFIX}/lib/kleened/ && ERTS_DIR=$$(${FIND} erts-* -depth 1 -type d) && \
		${STRIP_CMD} ${STAGEDIR}${PREFIX}/lib/kleened/$$ERTS_DIR/${bin}
.endfor

post-install:
	@cd ${STAGEDIR}${PREFIX} && \
		${FIND} lib/kleened/erts-* -type f -o -type l | ${SORT} >> ${TMPPLIST}
	@cd ${STAGEDIR}${PREFIX} && \
		${FIND} lib/kleened/lib/* -type f -o -type l | ${SORT} >> ${TMPPLIST}

.include <bsd.port.post.mk>
