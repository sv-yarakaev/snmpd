/*	$OpenBSD: parse.y,v 1.25 2013/03/29 12:53:41 gerhard Exp $	*/

/*
 * Copyright (c) 2007, 2008, 2012 Reyk Floeter <reyk@openbsd.org>
 * Copyright (c) 2004, 2005 Esben Norby <norby@openbsd.org>
 * Copyright (c) 2004 Ryan McBride <mcbride@openbsd.org>
 * Copyright (c) 2002, 2003, 2004 Henning Brauer <henning@openbsd.org>
 * Copyright (c) 2001 Markus Friedl.  All rights reserved.
 * Copyright (c) 2001 Daniel Hartmeier.  All rights reserved.
 * Copyright (c) 2001 Theo de Raadt.  All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

%{
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/queue.h>
#include <sys/tree.h>

#include <netinet/in.h>
#include <net/if.h>

#include <arpa/inet.h>
#include <arpa/nameser.h>

#include <ctype.h>
#include <unistd.h>
#include <err.h>
#include <errno.h>
#include <event.h>
#include <limits.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <netdb.h>
#include <string.h>
#include <syslog.h>

#include "snmpd.h"
#include "mib.h"

TAILQ_HEAD(files, file)		 files = TAILQ_HEAD_INITIALIZER(files);
static struct file {
	TAILQ_ENTRY(file)	 entry;
	FILE			*stream;
	char			*name;
	int			 lineno;
	int			 errors;
} *file, *topfile;
struct file	*pushfile(const char *, int);
int		 popfile(void);
int		 check_file_secrecy(int, const char *);
int		 yyparse(void);
int		 yylex(void);
int		 yyerror(const char *, ...);
int		 kw_cmp(const void *, const void *);
int		 lookup(char *);
int		 lgetc(int);
int		 lungetc(int);
int		 findeol(void);

TAILQ_HEAD(symhead, sym)	 symhead = TAILQ_HEAD_INITIALIZER(symhead);
struct sym {
	TAILQ_ENTRY(sym)	 entry;
	int			 used;
	int			 persist;
	char			*nam;
	char			*val;
};
int		 symset(const char *, const char *, int);
char		*symget(const char *);

struct snmpd			*conf = NULL;
static int			 errors = 0;
static struct addresslist	*hlist;
static struct usmuser		*user = NULL;

struct address	*host_v4(const char *);
struct address	*host_v6(const char *);
int		 host_dns(const char *, struct addresslist *,
		    int, in_port_t, struct ber_oid *, char *);
int		 host(const char *, struct addresslist *,
		    int, in_port_t, struct ber_oid *, char *);

typedef struct {
	union {
		int64_t		 number;
		char		*string;
		struct host	*host;
		struct timeval	 tv;
		struct ber_oid	*oid;
		struct {
			int		 type;
			void		*data;
			long long	 value;
		}		 data;
		enum usmauth	 auth;
		enum usmpriv	 enc;
	} v;
	int lineno;
} YYSTYPE;

%}

%token	INCLUDE
%token  LISTEN ON
%token	SYSTEM CONTACT DESCR LOCATION NAME OBJECTID SERVICES RTFILTER
%token	READONLY READWRITE OCTETSTRING INTEGER COMMUNITY TRAP RECEIVER
%token	SECLEVEL NONE AUTH ENC USER AUTHKEY ENCKEY ERROR DISABLED
%token	<v.string>	STRING
%token  <v.number>	NUMBER
%type	<v.string>	hostcmn
%type	<v.number>	optwrite yesno seclevel
%type	<v.data>	objtype
%type	<v.oid>		oid hostoid
%type	<v.auth>	auth
%type	<v.enc>		enc

%%

grammar		: /* empty */
		| grammar include '\n'
		| grammar '\n'
		| grammar varset '\n'
		| grammar main '\n'
		| grammar system '\n'
		| grammar mib '\n'
		| grammar error '\n'		{ file->errors++; }
		;

include		: INCLUDE STRING		{
			struct file	*nfile;

			if ((nfile = pushfile($2, 0)) == NULL) {
				yyerror("failed to include file %s", $2);
				free($2);
				YYERROR;
			}
			free($2);

			file = nfile;
			lungetc('\n');
		}
		;

varset		: STRING '=' STRING	{
			if (symset($1, $3, 0) == -1)
				fatal("cannot store variable");
			free($1);
			free($3);
		}
		;

yesno		:  STRING			{
			if (!strcmp($1, "yes"))
				$$ = 1;
			else if (!strcmp($1, "no"))
				$$ = 0;
			else {
				yyerror("syntax error, "
				    "either yes or no expected");
				free($1);
				YYERROR;
			}
			free($1);
		}
		;

main		: LISTEN ON STRING		{
			struct addresslist	 al;
			struct address		*h;

			TAILQ_INIT(&al);
			if (host($3, &al, 1, SNMPD_PORT, NULL, NULL) <= 0) {
				yyerror("invalid ip address: %s", $3);
				free($3);
				YYERROR;
			}
			free($3);
			h = TAILQ_FIRST(&al);
			bcopy(&h->ss, &conf->sc_address.ss, sizeof(*h));
			conf->sc_address.port = h->port;

			while ((h = TAILQ_FIRST(&al)) != NULL) {
				TAILQ_REMOVE(&al, h, entry);
				free(h);
			}
		}
		| READONLY COMMUNITY STRING	{
			if (strlcpy(conf->sc_rdcommunity, $3,
			    sizeof(conf->sc_rdcommunity)) >=
			    sizeof(conf->sc_rdcommunity)) {
				yyerror("r/o community name too long");
				free($3);
				YYERROR;
			}
			free($3);
		}
		| READWRITE COMMUNITY STRING	{
			if (strlcpy(conf->sc_rwcommunity, $3,
			    sizeof(conf->sc_rwcommunity)) >=
			    sizeof(conf->sc_rwcommunity)) {
				yyerror("r/w community name too long");
				free($3);
				YYERROR;
			}
			free($3);
		}
		| READWRITE DISABLED {
			conf->sc_readonly = 1;
 		}
		| TRAP COMMUNITY STRING		{
			if (strlcpy(conf->sc_trcommunity, $3,
			    sizeof(conf->sc_trcommunity)) >=
			    sizeof(conf->sc_trcommunity)) {
				yyerror("r/w community name too long");
				free($3);
				YYERROR;
			}
			free($3);
		}
		| TRAP RECEIVER			{
			hlist = &conf->sc_trapreceivers;
		} host				{
			hlist = NULL;
		}
		| RTFILTER yesno		{
			if ($2 == 1)
				conf->sc_rtfilter = ROUTE_FILTER(RTM_NEWADDR) |
				    ROUTE_FILTER(RTM_DELADDR) |
				    ROUTE_FILTER(RTM_IFINFO) |
				    ROUTE_FILTER(RTM_IFANNOUNCE);
			else
				conf->sc_rtfilter = 0;
		}
		| SECLEVEL seclevel {
			conf->sc_min_seclevel = $2;
		}
		| USER STRING			{
			const char *errstr;
			user = usm_newuser($2, &errstr);
			if (user == NULL) {
				yyerror(errstr);
				free($2);
				YYERROR;
			}
		} userspecs {
			const char *errstr;
			if (usm_checkuser(user, &errstr) < 0) {
				yyerror(errstr);
				YYERROR;
			}
			user = NULL;
		}
		;

system		: SYSTEM sysmib
		;

sysmib		: CONTACT STRING		{
			struct ber_oid	 o = OID(MIB_sysContact);
			mps_set(&o, $2, strlen($2));
		}
		| DESCR STRING			{
			struct ber_oid	 o = OID(MIB_sysDescr);
			mps_set(&o, $2, strlen($2));
		}
		| LOCATION STRING		{
			struct ber_oid	 o = OID(MIB_sysLocation);
			mps_set(&o, $2, strlen($2));
		}
		| NAME STRING			{
			struct ber_oid	 o = OID(MIB_sysName);
			mps_set(&o, $2, strlen($2));
		}
		| OBJECTID oid			{
			struct ber_oid	 o = OID(MIB_sysOID);
			mps_set(&o, $2, sizeof(struct ber_oid));
		}
		| SERVICES NUMBER		{
			struct ber_oid	 o = OID(MIB_sysServices);
			mps_set(&o, NULL, $2);
		}
		;

mib		: OBJECTID oid NAME STRING optwrite objtype	{
			struct oid	*oid;
			if ((oid = (struct oid *)
			    calloc(1, sizeof(*oid))) == NULL) {
				yyerror("calloc");
				free($2);
				free($6.data);
				YYERROR;
			}

			smi_oidlen($2);
			bcopy($2, &oid->o_id, sizeof(struct ber_oid));
			free($2);
			oid->o_name = $4;
			oid->o_data = $6.data;
			oid->o_val = $6.value;
			switch ($6.type) {
			case 1:
				oid->o_get = mps_getint;
				oid->o_set = mps_setint;
				break;
			case 2:
				oid->o_get = mps_getstr;
				oid->o_set = mps_setstr;
				break;
			}
			oid->o_flags = OID_RD|OID_DYNAMIC;
			if ($5)
				oid->o_flags |= OID_WR;

			smi_insert(oid);
		}
		;

objtype		: INTEGER NUMBER			{
			$$.type = 1;
			$$.data = NULL;
			$$.value = $2;
		}
		| OCTETSTRING STRING			{
			$$.type = 2;
			$$.data = $2;
			$$.value = strlen($2);
		}
		;

optwrite	: READONLY				{ $$ = 0; }
		| READWRITE				{ $$ = 1; }
		;

oid		: STRING				{
			struct ber_oid	*sysoid;
			if ((sysoid =
			    calloc(1, sizeof(*sysoid))) == NULL) {
				yyerror("calloc");
				free($1);
				YYERROR;
			}
			if (ber_string2oid($1, sysoid) == -1) {
				yyerror("invalid OID: %s", $1);
				free(sysoid);
				free($1);
				YYERROR;
			}
			free($1);
			$$ = sysoid;
		}
		;

hostoid		: /* empty */				{ $$ = NULL; }
		| OBJECTID oid				{ $$ = $2; }
		;

hostcmn		: /* empty */				{ $$ = NULL; }
		| COMMUNITY STRING			{ $$ = $2; }
		;

hostdef		: STRING hostoid hostcmn		{
			if (host($1, hlist, 1,
			    SNMPD_TRAPPORT, $2, $3) <= 0) {
				yyerror("invalid host: %s", $1);
				free($1);
				YYERROR;
			}
			free($1);
		}
		;

hostlist	: /* empty */
		| hostlist comma hostdef
		;

host		: hostdef
		| '{' hostlist '}'
		;

comma		: /* empty */
		| ','
		;

seclevel	: NONE		{ $$ = 0; }
		| AUTH		{ $$ = SNMP_MSGFLAG_AUTH; }
		| ENC		{ $$ = SNMP_MSGFLAG_AUTH | SNMP_MSGFLAG_PRIV; }
		;

userspecs	: /* empty */
		| userspecs userspec
		;

userspec	: AUTHKEY STRING		{
			user->uu_authkey = $2;
		}
		| AUTH auth			{
			user->uu_auth = $2;
		}
		| ENCKEY STRING			{
			user->uu_privkey = $2;
		}
		| ENC enc			{
			user->uu_priv = $2;
		}
		;

auth		: STRING			{
			if (strcasecmp($1, "hmac-md5") == 0 ||
			    strcasecmp($1, "hmac-md5-96") == 0)
				$$ = AUTH_MD5;
			else if (strcasecmp($1, "hmac-sha1") == 0 ||
			     strcasecmp($1, "hmac-sha1-96") == 0)
				$$ = AUTH_SHA1;
			else {
				yyerror("syntax error, bad auth hmac");
				free($1);
				YYERROR;
			}
			free($1);
		}
		;

enc		: STRING			{
			if (strcasecmp($1, "des") == 0 ||
			    strcasecmp($1, "cbc-des") == 0)
				$$ = PRIV_DES;
			else if (strcasecmp($1, "aes") == 0 ||
			    strcasecmp($1, "cfb128-aes-128") == 0)
				$$ = PRIV_AES;
			else {
				yyerror("syntax error, bad encryption cipher");
				free($1);
				YYERROR;
			}
			free($1);

		}
		;

%%

struct keywords {
	const char	*k_name;
	int		 k_val;
};

int
yyerror(const char *fmt, ...)
{
	va_list		 ap;
	char		*nfmt;

	file->errors++;
	va_start(ap, fmt);
	if (asprintf(&nfmt, "%s:%d: %s", file->name, yylval.lineno, fmt) == -1)
		fatalx("yyerror asprintf");
	vlog(LOG_CRIT, nfmt, ap);
	va_end(ap);
	free(nfmt);
	return (0);
}

int
kw_cmp(const void *k, const void *e)
{
	return (strcmp(k, ((const struct keywords *)e)->k_name));
}

int
lookup(char *s)
{
	/* this has to be sorted always */
	static const struct keywords keywords[] = {
		{ "auth",		AUTH },
		{ "authkey",		AUTHKEY },
		{ "community",		COMMUNITY },
		{ "contact",		CONTACT },
		{ "description",	DESCR },
		{ "disabled",		DISABLED},
		{ "enc",		ENC },
		{ "enckey",		ENCKEY },
		{ "filter-routes",	RTFILTER },
		{ "include",		INCLUDE },
		{ "integer",		INTEGER },
		{ "listen",		LISTEN },
		{ "location",		LOCATION },
		{ "name",		NAME },
		{ "none",		NONE },
		{ "oid",		OBJECTID },
		{ "on",			ON },
		{ "read-only",		READONLY },
		{ "read-write",		READWRITE },
		{ "receiver",		RECEIVER },
		{ "seclevel",		SECLEVEL },
		{ "services",		SERVICES },
		{ "string",		OCTETSTRING },
		{ "system",		SYSTEM },
		{ "trap",		TRAP },
		{ "user",		USER }
	};
	const struct keywords	*p;

	p = bsearch(s, keywords, sizeof(keywords)/sizeof(keywords[0]),
	    sizeof(keywords[0]), kw_cmp);

	if (p)
		return (p->k_val);
	else
		return (STRING);
}

#define MAXPUSHBACK	128

char	*parsebuf;
int	 parseindex;
char	 pushback_buffer[MAXPUSHBACK];
int	 pushback_index = 0;

int
lgetc(int quotec)
{
	int		c, next;

	if (parsebuf) {
		/* Read character from the parsebuffer instead of input. */
		if (parseindex >= 0) {
			c = parsebuf[parseindex++];
			if (c != '\0')
				return (c);
			parsebuf = NULL;
		} else
			parseindex++;
	}

	if (pushback_index)
		return (pushback_buffer[--pushback_index]);

	if (quotec) {
		if ((c = getc(file->stream)) == EOF) {
			yyerror("reached end of file while parsing quoted string");
			if (file == topfile || popfile() == EOF)
				return (EOF);
			return (quotec);
		}
		return (c);
	}

	while ((c = getc(file->stream)) == '\\') {
		next = getc(file->stream);
		if (next != '\n') {
			c = next;
			break;
		}
		yylval.lineno = file->lineno;
		file->lineno++;
	}
	if (c == '\t' || c == ' ') {
		/* Compress blanks to a single space. */
		do {
			c = getc(file->stream);
		} while (c == '\t' || c == ' ');
		ungetc(c, file->stream);
		c = ' ';
	}

	while (c == EOF) {
		if (file == topfile || popfile() == EOF)
			return (EOF);
		c = getc(file->stream);
	}
	return (c);
}

int
lungetc(int c)
{
	if (c == EOF)
		return (EOF);
	if (parsebuf) {
		parseindex--;
		if (parseindex >= 0)
			return (c);
	}
	if (pushback_index < MAXPUSHBACK-1)
		return (pushback_buffer[pushback_index++] = c);
	else
		return (EOF);
}

int
findeol(void)
{
	int	c;

	parsebuf = NULL;

	/* skip to either EOF or the first real EOL */
	while (1) {
		if (pushback_index)
			c = pushback_buffer[--pushback_index];
		else
			c = lgetc(0);
		if (c == '\n') {
			file->lineno++;
			break;
		}
		if (c == EOF)
			break;
	}
	return (ERROR);
}

int
yylex(void)
{
	char	 buf[8096];
	char	*p, *val;
	int	 quotec, next, c;
	int	 token;

top:
	p = buf;
	while ((c = lgetc(0)) == ' ' || c == '\t')
		; /* nothing */

	yylval.lineno = file->lineno;
	if (c == '#')
		while ((c = lgetc(0)) != '\n' && c != EOF)
			; /* nothing */
	if (c == '$' && parsebuf == NULL) {
		while (1) {
			if ((c = lgetc(0)) == EOF)
				return (0);

			if (p + 1 >= buf + sizeof(buf) - 1) {
				yyerror("string too long");
				return (findeol());
			}
			if (isalnum(c) || c == '_') {
				*p++ = (char)c;
				continue;
			}
			*p = '\0';
			lungetc(c);
			break;
		}
		val = symget(buf);
		if (val == NULL) {
			yyerror("macro '%s' not defined", buf);
			return (findeol());
		}
		parsebuf = val;
		parseindex = 0;
		goto top;
	}

	switch (c) {
	case '\'':
	case '"':
		quotec = c;
		while (1) {
			if ((c = lgetc(quotec)) == EOF)
				return (0);
			if (c == '\n') {
				file->lineno++;
				continue;
			} else if (c == '\\') {
				if ((next = lgetc(quotec)) == EOF)
					return (0);
				if (next == quotec || c == ' ' || c == '\t')
					c = next;
				else if (next == '\n') {
					file->lineno++;
					continue;
				} else
					lungetc(next);
			} else if (c == quotec) {
				*p = '\0';
				break;
			}
			if (p + 1 >= buf + sizeof(buf) - 1) {
				yyerror("string too long");
				return (findeol());
			}
			*p++ = (char)c;
		}
		yylval.v.string = strdup(buf);
		if (yylval.v.string == NULL)
			err(1, "yylex: strdup");
		return (STRING);
	}

#define allowed_to_end_number(x) \
	(isspace(x) || x == ')' || x ==',' || x == '/' || x == '}' || x == '=')

	if (c == '-' || isdigit(c)) {
		do {
			*p++ = c;
			if ((unsigned)(p-buf) >= sizeof(buf)) {
				yyerror("string too long");
				return (findeol());
			}
		} while ((c = lgetc(0)) != EOF && isdigit(c));
		lungetc(c);
		if (p == buf + 1 && buf[0] == '-')
			goto nodigits;
		if (c == EOF || allowed_to_end_number(c)) {
			const char *errstr = NULL;

			*p = '\0';
			yylval.v.number = strtonum(buf, LLONG_MIN,
			    LLONG_MAX, &errstr);
			if (errstr) {
				yyerror("\"%s\" invalid number: %s",
				    buf, errstr);
				return (findeol());
			}
			return (NUMBER);
		} else {
nodigits:
			while (p > buf + 1)
				lungetc(*--p);
			c = *--p;
			if (c == '-')
				return (c);
		}
	}

#define allowed_in_string(x) \
	(isalnum(x) || (ispunct(x) && x != '(' && x != ')' && \
	x != '{' && x != '}' && \
	x != '!' && x != '=' && x != '#' && \
	x != ','))

	if (isalnum(c) || c == ':' || c == '_') {
		do {
			*p++ = c;
			if ((unsigned)(p-buf) >= sizeof(buf)) {
				yyerror("string too long");
				return (findeol());
			}
		} while ((c = lgetc(0)) != EOF && (allowed_in_string(c)));
		lungetc(c);
		*p = '\0';
		if ((token = lookup(buf)) == STRING)
			if ((yylval.v.string = strdup(buf)) == NULL)
				err(1, "yylex: strdup");
		return (token);
	}
	if (c == '\n') {
		yylval.lineno = file->lineno;
		file->lineno++;
	}
	if (c == EOF)
		return (0);
	return (c);
}

int
check_file_secrecy(int fd, const char *fname)
{
	struct stat	st;

	if (fstat(fd, &st)) {
		log_warn("cannot stat %s", fname);
		return (-1);
	}
	if (st.st_uid != 0 && st.st_uid != getuid()) {
		log_warnx("%s: owner not root or current user", fname);
		return (-1);
	}
	if (st.st_mode & (S_IRWXG | S_IRWXO)) {
		log_warnx("%s: group/world readable/writeable", fname);
		return (-1);
	}
	return (0);
}

struct file *
pushfile(const char *name, int secret)
{
	struct file	*nfile;

	if ((nfile = calloc(1, sizeof(struct file))) == NULL) {
		log_warn("malloc");
		return (NULL);
	}
	if ((nfile->name = strdup(name)) == NULL) {
		log_warn("malloc");
		free(nfile);
		return (NULL);
	}
	if ((nfile->stream = fopen(nfile->name, "r")) == NULL) {
		log_warn("%s", nfile->name);
		free(nfile->name);
		free(nfile);
		return (NULL);
	} else if (secret &&
	    check_file_secrecy(fileno(nfile->stream), nfile->name)) {
		fclose(nfile->stream);
		free(nfile->name);
		free(nfile);
		return (NULL);
	}
	nfile->lineno = 1;
	TAILQ_INSERT_TAIL(&files, nfile, entry);
	return (nfile);
}

int
popfile(void)
{
	struct file	*prev;

	if ((prev = TAILQ_PREV(file, files, entry)) != NULL)
		prev->errors += file->errors;

	TAILQ_REMOVE(&files, file, entry);
	fclose(file->stream);
	free(file->name);
	free(file);
	file = prev;
	return (file ? 0 : EOF);
}

struct snmpd *
parse_config(const char *filename, u_int flags)
{
	struct sym	*sym, *next;

	if ((conf = calloc(1, sizeof(*conf))) == NULL) {
		log_warn("cannot allocate memory");
		return (NULL);
	}

	conf->sc_flags = flags;
	conf->sc_confpath = filename;
