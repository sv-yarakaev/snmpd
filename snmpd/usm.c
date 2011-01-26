/*	$OpenBSD: usm.c,v 1.6 2013/01/24 09:30:27 gerhard Exp $	*/

/*
 * Copyright (c) 2012 GeNUA mbH
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

#include <sys/queue.h>
#include <sys/param.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/tree.h>

#include <net/if.h>

#include <errno.h>
#include <event.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#ifdef DEBUG
#include <assert.h>
#endif

#include <openssl/evp.h>
#include <openssl/hmac.h>

#include "snmpd.h"
#include "mib.h"

extern struct snmpd	*env;

SLIST_HEAD(, usmuser)	usmuserlist;

const EVP_MD		*usm_get_md(enum usmauth);
const EVP_CIPHER	*usm_get_cipher(enum usmpriv);
void			 usm_cb_digest(void *, size_t);
int			 usm_valid_digest(struct snmp_message *, off_t, char *,
			    size_t);
struct ber_element	*usm_decrypt(struct snmp_message *,
			    struct ber_element *);
ssize_t			 usm_crypt(struct snmp_message *, u_char *, int,
			    u_char *, int);
char			*usm_passwd2key(const EVP_MD *, char *, int *);

void
usm_generate_keys(void)
{
	struct usmuser	*up;
	const EVP_MD	*md;
	char		*key;
	int		 len;

	SLIST_FOREACH(up, &usmuserlist, uu_next) {
		if ((md = usm_get_md(up->uu_auth)) == NULL)
			continue;

		/* convert auth password to key */
		len = 0;
		key = usm_passwd2key(md, up->uu_authkey, &len);
		free(up->uu_authkey);
		up->uu_authkey = key;
		up->uu_authkeylen = len;

		/* optionally convert privacy password to key */
		if (up->uu_priv != PRIV_NONE) {
			arc4random_buf(&up->uu_salt, sizeof(up->uu_salt));

			len = SNMP_CIPHER_KEYLEN;
			key = usm_passwd2key(md, up->uu_privkey, &len);
			free(up->uu_privkey);
			up->uu_privkey = key;
		}
	}
	return;
}

const EVP_MD *
usm_get_md(enum usmauth ua)
{
	switch (ua) {
	case AUTH_MD5:
		return EVP_md5();
	case AUTH_SHA1:
		return EVP_sha1();
	case AUTH_NONE:
	default:
		return NULL;
	}
}

const EVP_CIPHER *
usm_get_cipher(enum usmpriv up)
{
	switch (up) {
	case PRIV_DES:
		return EVP_des_cbc();
	case PRIV_AES:
		return EVP_aes_128_cfb128();
	case PRIV_NONE:
	default:
		return NULL;
	}
}

struct usmuser *
usm_newuser(char *name, const char **errp)
{
	struct usmuser *up = usm_finduser(name);
	if (up != NULL) {
		*errp = "user redefined";
		return NULL;
	}
	if ((up = calloc(1, sizeof(*up))) == NULL)
		fatal("usm");
	up->uu_name = name;
	SLIST_INSERT_HEAD(&usmuserlist, up, uu_next);
	return up;
}

struct usmuser *
usm_finduser(char *name)
{
	struct usmuser *up;

	SLIST_FOREACH(up, &usmuserlist, uu_next) {
		if (!strcmp(up->uu_name, name))
			return up;
	}
	return NULL;
}

int
usm_checkuser(struct usmuser *up, const char **errp)
{
	char	*auth = NULL, *priv = NULL;

	if (up->uu_auth != AUTH_NONE && up->uu_authkey == NULL) {
		*errp = "missing auth passphrase";
		goto fail;
	} else if (up->uu_auth == AUTH_NONE && up->uu_authkey != NULL)
		up->uu_auth = AUTH_DEFAULT;

	if (up->uu_priv != PRIV_NONE && up->uu_privkey == NULL) {
		*errp = "missing priv passphrase";
		goto fail;
	} else if (up->uu_priv == PRIV_NONE && up->uu_privkey != NULL)
		up->uu_priv = PRIV_DEFAULT;

	if (up->uu_auth == AUTH_NONE && up->uu_priv != PRIV_NONE) {
		/* Standard prohibits noAuthPriv */
		*errp = "auth is mandatory with enc";
		goto fail;
	}

	switch (up->uu_auth) {
	case AUTH_NONE:
		auth = "none";
		break;
	case AUTH_MD5:
		up->uu_seclevel |= SNMP_MSGFLAG_AUTH;
		auth = "HMAC-MD5-96";
		break;
	case AUTH_SHA1:
		up->uu_seclevel |= SNMP_MSGFLAG_AUTH;
		auth = "HMAC-SHA1-96";
		break;
	}

	switch (up->uu_priv) {
	case PRIV_NONE:
		priv = "none";
		break;
	case PRIV_DES:
		up->uu_seclevel |= SNMP_MSGFLAG_PRIV;
		priv = "CBC-DES";
		break;
	case PRIV_AES:
		up->uu_seclevel |= SNMP_MSGFLAG_PRIV;
		priv = "CFB128-AES-128";
		break;
	}

	log_debug("user \"%s\" auth %s enc %s", up->uu_name, auth, priv);
	return 0;

fail:
	free(up->uu_name);
	free(up->uu_authkey);
	free(up->uu_privkey);
	SLIST_REMOVE(&usmuserlist, up, usmuser, uu_next);
	free(up);
	return -1;
}

struct ber_element *
usm_decode(struct snmp_message *msg, struct ber_element *elm, const char **errp)
{
	struct snmp_stats	*stats = &env->sc_stats;
	off_t			 offs, offs2;
	char			*usmparams;
	size_t			 len;
	size_t			 enginelen, userlen, digestlen, saltlen;
	struct ber		 ber;
	struct ber_element	*usm = NULL, *next = NULL, *decr;
	char			*engineid;
	char			*user;
	char			*digest, *salt;
	u_long			 now;
	long long		 engine_boots, engine_time;

