﻿unit SCrypt;

(*
	Sample Usage
	============

		secretKey := TScrypt.GetBytes('correct horse battery staple', 'seasalt', 16); //returns 16 bytes (128 bits)
		secretKey := TScrypt.GetBytes('correct horse battery staple', 'seasalt', {r}1, {N}128}, {p}8, 32); //returns 32 bytes (256 bits)

	Remarks
	=======

	scrypt is a key-derivation function.
	Key derivation functions are used to derive an encryption key from a password.

	To generate 16 bytes (128 bits) of key material, using scrypt determined parameters use:

		secretKey := TScrypt.GetBytes('correct horse battery staple', 'seasalt', 16); //returns 16 bytes (128 bits)

	If you know what values of the N (CostFactor), r (block size), and p (parallelization factor) scrypt
	parameters you want, you can specify them:

			secretKey := TScrypt.GetBytes('correct horse battery staple', 'seasalt', {N=14}, {r=}8, {p=}1, 32); //returns 32 bytes (256 bits)

   where
			BlockSize (r) = 8
			CostFactor (N) = 14 (i.e. 2^14 = 16384 iterations)
			ParallelizationFactor (p) = 1
			DesiredBytes = 32 (256 bits)

	Otherwise scrypt does a speed/memory test to determine the most appropriate parameters.

	Password Hashing
	================

	SCrypt has also been used as password hashing algorithm.
	In order to make password storage easier, we will generate the salt and store it with the
	returned string. This is similar to what OpenBSD has done with BCrypt.
	The downside is that there is no standard out there for SCrypt representation of password hashes.

		hash := TSCrypt.HashPassword('correct horse battery staple', 'seasalt');

	will return string in the format of:

	$s0$params$salt$key

	  s0     - version 0 of the format with 128-bit salt and 256-bit derived key
	  params - 32-bit hex integer containing log2(N) (16 bits), r (8 bits), and p (8 bits)
	  salt   - base64-encoded salt
	  key    - base64-encoded derived key

	  Example:

	    $s0$e0801$epIxT/h6HbbwHaehFnh/bw==$7H0vsXlY8UxxyW/BWx/9GuY7jEvGjT71GFd6O4SZND0=

	    passwd = "secret"
	         N = 14
	         r = 8
	         p = 1

	Version History
	===============

	Version 1.0   20150408
			- Inital release. Public domain.  Ian Boyd.
			  This is free and unencumbered software released into the public domain.
			  Anyone is free to copy, modify, publish, use, compile, sell, or
			  distribute this software, either in source code form or as a compiled
			  binary, for any purpose, commercial or non-commercial, and by any
			  means.
			  For more information, please refer to <http://unlicense.org>

	References
	==============
	The scrypt Password-Based Key Derivation Function
		http://tools.ietf.org/html/draft-josefsson-scrypt-kdf-02

	Java implementation of scrypt
		https://github.com/wg/scrypt

	Scrypt For Node/IO
		https://github.com/barrysteyn/node-scrypt
*)

interface

uses
	SysUtils, System.Types;

type
	//As basic of a Hash interface as you can get
	IHashAlgorithm = interface(IInterface)
		['{985B0964-C47A-4212-ADAA-C57B26F02CCD}']
		function GetBlockSize: Integer;
		function GetDigestSize: Integer;

		{ Methods }
		procedure HashData(const Buffer; BufferLen: Integer);
		function Finalize: TBytes;

		{ Properties }
		property BlockSize: Integer read GetBlockSize;
		property DigestSize: Integer read GetDigestSize;
	end;

	TScrypt = class(TObject)
	private
		FHash: IHashAlgorithm;
	protected
		function StringToBytes(const s: string): TBytes;

		procedure XorBlockInPlace(var A; const B; Length: Integer); inline;

		function PBKDF2(const Hash: IHashAlgorithm; const Password: UnicodeString; const Salt; const SaltLength: Integer; IterationCount, DesiredBytes: Integer): TBytes;
		function HMAC(const Hash: IHashAlgorithm; const Key; KeyLen: Integer; const Data; DataLen: Integer): TBytes;

		function Salsa20(const Input): TBytes; //four round version of Salsa20, termed Salsa20/8
		procedure Salsa20InPlace(var Input);
		function BlockMix(const B: array of Byte): TBytes; //mixes r 128-byte blocks
		function ROMix(const B; BlockSize, CostFactor: Cardinal): TBytes;

		function Core(const Passphrase, Salt: UnicodeString; const CostFactor, BlockSizeFactor, ParallelizationFactor: UInt64; DesiredBytes: Integer): TBytes;

		function Integerify(const B: array of Byte; const N: Integer): Integer; //X mod N

		{
			Let people have access to our hash functions. They've been tested and verified, and they work well.
			Besides, we have HMAC and PBKDF2. That's gotta be useful for someone.
		}
		class function GetHashAlgorithm(const HashAlgorithmName: string): IHashAlgorithm;
	public
		constructor Create;

		//Get a number of bytes using the default Cost and Parallelization factors
		class function GetBytes(const Passphrase: UnicodeString; const Salt: UnicodeString; nDesiredBytes: Integer): TBytes; overload;

		//Get a number of bytes, specifying the desired cost and parallelization factor
		class function GetBytes(const Passphrase: UnicodeString; const Salt: UnicodeString; CostFactor, BlockSizeFactor, ParallelizationFactor: Cardinal; DesiredBytes: Integer): TBytes; overload;

		{
			Scrypt is not meant for password storage; it is meant for key generation.
			But people can still use it for password hashing.
			Unlike Bcrypt, there is no standard representation for passwords hashed with Scrypt.
			So we can make one, and provide the function to validate it
		}
		class function HashPassword(const Passphrase: UnicodeString): string; overload;
		class function HashPassword(const Passphrase: UnicodeString; CostFactor, BlockSizeFactor, Parallelization: Cardinal): string; overload;
		class function CheckPassword(const Passphrase: UnicodeString; ExpectedPassword: UnicodeString): Boolean;

	end;

	EScryptException = class(Exception);

implementation

uses
	Windows, Math;

type
	PLongWordArray = ^TLongWordArray_Unsafe;
	TLongWordArray_Unsafe = array[0..15] of LongWord;

function RRot32(X: LongWord; c: Byte): LongWord; inline;
begin
	Result := (X shr c) or (X shl (32-c));
end;

function LRot32(X: LongWord; c: Byte): LongWord; inline;
{IFDEF PUREPASCAL}
begin
	Result := (X shl c) or (X shr (32-c));
{ELSE !PUREPASCAL}
(*	{$IFDEF CPUX86}
	asm
		MOV cl, c;
		ROL eax, cl;
	{$ENDIF CPUX86}
	{$IFDEF CPUX64}
	//http://blogs.msdn.com/b/oldnewthing/archive/2004/01/14/58579.aspx
	//In x64 calling convention the first four parameters are passed in rcx, rdx, r8, r9
	//Return value is in RAX
	asm
		MOV eax, ecx; //store result in eax
		MOV cl, c;    //rol left only supports from rolling from cl
		ROL eax, cl;
	{$ENDIF}
*)
{ENDIF !PUREPASCAL}
end;

function ByteSwap(const X: Cardinal): Cardinal; inline;
begin
{
	Reverses the byte order of a 32-bit register.
}
	Result :=
			( X shr 24) or
			((X shr  8) and $00FF00) or
			((X shl  8) and $FF0000) or
			( X shl 24);
end;

procedure RaiseOSError(ErrorCode: DWORD; Msg: string);
var
	ex: EOSError;
begin
	ex := EOSError.Create(Msg);
	ex.ErrorCode := error;
	raise Ex;
end;

type
	HCRYPTPROV = THandle;
	HCRYPTHASH = THandle;
	HCRYPTKEY = THandle;
	ALG_ID = LongWord; //unsigned int


{ SHA1 implemented in Pascal}
type
	TSHA1 = class(TInterfacedObject, IHashAlgorithm)
	private
		FInitialized: Boolean;
		FHashLength: TULargeInteger; //Number of bits put into the hash
		FHashBuffer: array[0..63] of Byte;  //one step before W0..W15
		FHashBufferIndex: Integer;  //Current position in HashBuffer
		FABCDEBuffer: array[0..4] of LongWord; //working hash buffer is 160 bits (20 bytes)
		procedure Compress;
		procedure UpdateLen(NumBytes: LongWord);
		procedure Burn;
	protected
		procedure HashCore(const Data; DataLen: Integer);
		function HashFinal: TBytes;

		function GetBlockSize: Integer;
		function GetDigestSize: Integer;

		procedure Initialize;
	public
		constructor Create;

		procedure HashData(const Buffer; BufferLen: Integer);
		function Finalize: TBytes;

		procedure SelfTest;
	end;

{
	SHA-1 implemented by Microsoft Crypto Service Provider (CSP)
}
	TSHA1csp = class(TInterfacedObject, IHashAlgorithm)
	private
		FProvider: HCRYPTPROV;
		FHash: HCRYPTHASH;
	protected
		function GetBlockSize: Integer; //SHA-1 compresses in blocks of 64 bytes
		function GetDigestSize: Integer; //SHA-1 digest is 20 bytes (160 bits)

		procedure Initialize;
		procedure Burn;
		procedure HashCore(const Data; DataLen: Integer);
		function HashFinal: TBytes;
	public
		constructor Create;
		destructor Destroy; override;

		procedure HashData(const Buffer; BufferLen: Integer);
		function Finalize: TBytes;
	end;

{
	SHA256 implemented in Pascal
}
type
	TSHA256 = class(TInterfacedObject, IHashAlgorithm)
	private
		FInitialized: Boolean;
		FHashLength: TULargeInteger; //Number of bits put into the hash
		FHashBuffer: array[0..63] of Byte;  //one step before W0..W15
		FHashBufferIndex: Integer;  //Current position in HashBuffer
		FCurrentHash: array[0..7] of LongWord;
		procedure Compress;
		procedure UpdateLen(NumBytes: LongWord);
		procedure Burn;
	protected
		function GetBlockSize: Integer;
		function GetDigestSize: Integer;

		procedure HashCore(const Data; DataLen: Integer);
		function HashFinal: TBytes;

		procedure Initialize;
	public
		constructor Create;

		procedure HashData(const Buffer; BufferLen: Integer);
		function Finalize: TBytes;
	end;

{
	SHA-256 implemented by Microsoft Crypto Service Provider (CSP)
}
	TSHA256csp = class(TInterfacedObject, IHashAlgorithm)
	private
		FProvider: HCRYPTPROV;
		FHash: HCRYPTHASH;
	protected
		function GetBlockSize: Integer;
		function GetDigestSize: Integer;

		procedure Initialize;
		procedure Burn;
		procedure HashCore(const Data; DataLen: Integer);
		function HashFinal: TBytes;
	public
		constructor Create;
		destructor Destroy; override;

		procedure HashData(const Buffer; BufferLen: Integer);
		function Finalize: TBytes;
	end;

{ TScrypt }

class function TScrypt.GetBytes(const Passphrase, Salt: UnicodeString; nDesiredBytes: Integer): TBytes;
const
	N_interactive = 14; //2^14
//	N_sensitive = 20; //2^20
	r = 8;
	p = 1;
begin
	Result := TScrypt.GetBytes(Passphrase, Salt, N_interactive, r, p, nDesiredBytes);
end;

function TScrypt.BlockMix(const B: array of Byte): TBytes;
var
	r: Integer;
	X: array[0..15] of LongWord;
	i: Integer;
	Y: TBytes;
	ne, no: Integer; //index even, index odd
begin
{
	Mix r 128-byte blocks (which is equivalent of saying 2r 64-byte blocks)
}
	//Make sure we actually have an even multiple of 128 bytes
	if Length(B) mod 128 <> 0 then
		raise EScryptException.Create('');
	r := Length(B) div 128;

	SetLength(Y, 128*r);

	//X ← B[2*r-1]
	//Copy last 64-byte block into X.
	Move(B[64*(2*r-1)], X[0], 64);


	for i := 0 to 2*r-1 do
	begin
		//T = X xor B[i]
		XorBlockInPlace(X[0], B[64*i], 64);

		//X = Salsa (T)
		Self.Salsa20InPlace(X[0]);

		//Y[i] = X
      Move(X[0], Y[64*i], 64);
	end;

	{
		Result = Y[0],Y[2],Y[4], ..., Y[2*r-2], Y[1],Y[3],Y[5], ..., Y[2*r-1]

		Result[ 0] := Y[ 0];
		Result[ 1] := Y[ 2];
		Result[ 2] := Y[ 4];
		Result[ 3] := Y[ 6];
		Result[ 4] := Y[ 8];
		Result[ 5] := Y[10];
		Result[ 6] := Y[ 1];
		Result[ 7] := Y[ 3];
		Result[ 8] := Y[ 5];
		Result[ 9] := Y[ 7];
		Result[10] := Y[ 9];
		Result[11] := Y[11];

		Result[ 0] := Y[ 0];
		Result[ 6] := Y[ 1];
		Result[ 1] := Y[ 2];
		Result[ 7] := Y[ 3];
		Result[ 2] := Y[ 4];
		Result[ 8] := Y[ 5];
		Result[ 3] := Y[ 6];
		Result[ 9] := Y[ 7];
		Result[ 4] := Y[ 8];
		Result[10] := Y[ 9];
		Result[ 5] := Y[10];
		Result[11] := Y[11];

	}
	SetLength(Result, Length(B));
	i := 0;
	ne := 0;
	no := r;
	while (i <= 2*r-1) do
	begin
		Move(Y[64*(i  )], Result[64*ne], 64);
		Move(Y[64*(i+1)], Result[64*no], 64);
		Inc(ne, 1);
		Inc(no, 1);
		Inc(i, 2);
   end;
end;

class function TScrypt.CheckPassword(const Passphrase: UnicodeString; ExpectedPassword: UnicodeString): Boolean;
begin
	raise Exception.Create('Not implemented');
	Result := False;
end;

function TScrypt.Core(const Passphrase, Salt: UnicodeString;
		const CostFactor, BlockSizeFactor, ParallelizationFactor: UInt64; DesiredBytes: Integer): TBytes;
var
	saltUtf8: TBytes;
	B: TBytes;
	i: UInt64;
	blockSize: Integer;
	blockIndex: Integer;
	T: TBytes;
begin
	blockSize := 128*BlockSizeFactor;

	saltUtf8 := TEncoding.UTF8.GetBytes(Salt);

	//Step 1. Use PBKDF2 to generate the initial blocks
	B := Self.PBKDF2(FHash, Passphrase, saltUtf8[0], Length(saltUtf8), 1, ParallelizationFactor*blockSize);

	//Step 2. Run RoMix on each block
	{
		Each each ROMix operation can run in parallal on each block.
		But the downside is that each ROMix itself will consume blockSize*Cost memory.

		LiteCoin uses
			blockSize: 128 bytes (r=1)
			parallelizationFactor: 1 (p=1)
			Cost: 1,024 (costFactor=10 ==> 2^10 = 1024)

			B: [128]

	}
	i := 0;
	while i < ParallelizationFactor do
	begin
		//B[i] ← ROMix(B[i])
		blockIndex := i*blockSize;
		T := Self.ROMix(B[blockIndex], blockSize, CostFactor);
		Move(T[0], B[blockIndex], blockSize);
		Inc(i);
	end;

	//Step 3. Use PBDKF2 with out password, but use B as the salt
	Result := Self.PBKDF2(FHash, Passphrase, B[0], ParallelizationFactor*blockSize, 1, DesiredBytes);
end;

constructor TScrypt.Create;
begin
	inherited Create;

{$IFDEF MSWINDOWS}
	FHash := TSHA256csp.Create;
{$ELSE}
	FHash := TSHA256.Create;
{$ENDIF}
end;

class function TScrypt.GetBytes(const Passphrase, Salt: UnicodeString; CostFactor, BlockSizeFactor, ParallelizationFactor: Cardinal; DesiredBytes: Integer): TBytes;
var
	scrypt: TScrypt;
begin
	scrypt := TScrypt.Create;
	try
		Result := scrypt.Core(Passphrase, Salt, CostFactor, BlockSizeFactor, ParallelizationFactor, DesiredBytes);
   finally
		scrypt.Free;
   end;
end;

class function TScrypt.GetHashAlgorithm(const HashAlgorithmName: string): IHashAlgorithm;
const
	sha1='TSHA1';
	sha1csp='TSHA1csp';
	sha256='TSHA256';
	sha256csp='TSHA256csp';
begin
	{
		We contain a number of hash algorithms.
		It might be nice to let people outside us to get ahold of them.

		| HashAlgorithmName | Class         | Description                  |
		|-------------------|---------------|------------------------------|
		| 'TSHA1'           | TSHA1         | SHA-1, native Pascal         |
		| 'TSHA1csp'        | TSHA1csp      | SHA-1 using Microsoft CSP    |
		| 'TSHA256'         | TSHA256       | SHA2-256, native Pascal      |
		| 'TSHA256csp'      | TSHA256csp    | ShA2-256 using Microsoft CSP |
	}
	if AnsiSameText(HashAlgorithmName, sha1) then
		Result := TSHA1.Create
   else if AnsiSameText(HashAlgorithmName, sha1csp) then
		Result := TSHA1csp.Create
	else if AnsiSameText(HashAlgorithmName, sha256) then
		Result := TSHA256.Create
	else if AnsiSameText(HashAlgorithmName, sha256csp) then
		Result := TSHA256csp.Create
	else
		raise Exception.CreateFmt('Unknown hash algorithm "%s" requested', [HashAlgorithmName]);
end;

class function TScrypt.HashPassword(const Passphrase: UnicodeString): string;
var
	costFactor: Cardinal;
	blockSize: Cardinal;
	parallelizationFactor: Cardinal;
begin
	costFactor := 14; //i.e. 2^14 = 16,384 iterations
	blockSize := 8; //will operate on 8*128 = 1,024 byte blocks
	parallelizationFactor := 1;

	Result := TScrypt.HashPassword(Passphrase, costFactor, blockSize, parallelizationFactor);
end;

class function TScrypt.HashPassword(const Passphrase: UnicodeString; CostFactor, BlockSizeFactor, Parallelization: Cardinal): string;
begin
{
	Someone already decided on a standard string way to represent scrypt passwords.
		https://github.com/wg/scrypt

	We'll gravitate to any existing standard we can find

	$s0$params$salt$key

	  s0     - version 0 of the format with 128-bit salt and 256-bit derived key
	  params - 32-bit hex integer containing log2(N) (16 bits), r (8 bits), and p (8 bits)
	  salt   - base64-encoded salt
	  key    - base64-encoded derived key

  Example:

    $s0$e0801$epIxT/h6HbbwHaehFnh/bw==$7H0vsXlY8UxxyW/BWx/9GuY7jEvGjT71GFd6O4SZND0=

    passwd = "secret"
         N = 16384
         r = 8
			p = 1
}


{
	There is another standard out there, published by the guy who authored the rfc.


	Unix crypt using scrypt
	https://gitorious.org/scrypt/ietf-scrypt/raw/7c4a7c47d32a5dbfd43b1223e4b9ac38bfe6f8a0:unix-scrypt.txt
      -----------------------

      This document specify a new Unix crypt method based on the scrypt
      password-based key derivation function.  It uses the

         $<ID>$<SALT>$<PWD>

      convention introduced with the old MD5-based solution and also used by
      the more recent SHA-256/SHA-512 mechanism specified here:

        http://www.akkadia.org/drepper/sha-crypt.html

      The scrypt method uses the following value:


           ID       |    Method
        -------------------------------
           7        |    scrypt

      The scrypt method requires three parameters in the SALT value: N, r
      and p which are expressed like this:

        N=<N>,r=<r>,p=<p>$

      where N, r and p are unsigned decimal numbers that are used as the
      scrypt parameters.

      The PWD part is the password string, and the size is fixed to 86
      characters which corresponds to 64 bytes base64 encoded.

      To compute the PWD part, run the scrypt algorithm with the password,
      salt, parameters to generate 64 bytes and base64 encode it.
}

{
	And then theres:

	https://github.com/jvarho/pylibscrypt/blob/master/pylibscrypt/mcf.py

   Modular Crypt Format support for scrypt

   Compatible with libscrypt scrypt_mcf_check also supports the $7$ format.

   libscrypt format:

	   $s1$NNrrpp$salt$hash
	   NN   - hex encoded N log2 (two hex digits)
	   rr   - hex encoded r in 1-255
	   pp   - hex encoded p in 1-255
	   salt - base64 encoded salt 1-16 bytes decoded
	   hash - base64 encoded 64-byte scrypt hash

   $7$ format:
	   $7$Nrrrrrpppppsalt$hash
	   N     - crypt base64 N log2
	   rrrrr - crypt base64 r (little-endian 30 bits)
	   ppppp - crypt base64 p (little-endian 30 bits)
	   salt  - raw salt (0-43 bytes that should be limited to crypt base64)
	   hash  - crypt base64 encoded 32-byte scrypt hash (43 bytes)
}


end;

function TScrypt.HMAC(const Hash: IHashAlgorithm; const Key; KeyLen: Integer; const Data; DataLen: Integer): TBytes;
var
	oKeyPad, iKeyPad: TBytes;
	i: Integer;
	digest: TBytes;
	blockSize: Integer;
begin
	{
		Implementation of RFC2104  HMAC: Keyed-Hashing for Message Authentication

		Tested with known test vectors from RFC2202: Test Cases for HMAC-MD5 and HMAC-SHA-1
	}
	blockSize := Hash.BlockSize;

	// Clear pads
	SetLength(oKeyPad, blockSize); //elements will be initialized to zero by SetLength
	SetLength(iKeyPad, blockSize); //elements will be initialized to zero by SetLength

	// if key is longer than blocksize: reset it to key=Hash(key)
   if KeyLen > blockSize then
   begin
		Hash.HashData(Key, KeyLen);
		digest := Hash.Finalize;

      //Store hashed key in pads
		Move(digest[0], iKeyPad[0], Length(digest)); //remaining bytes will remain zero
		Move(digest[0], oKeyPad[0], Length(digest)); //remaining bytes will remain zero
   end
   else
   begin
		//Store original key in pads
      Move(Key, iKeyPad[0], KeyLen); //remaining bytes will remain zero
      Move(Key, oKeyPad[0], KeyLen); //remaining bytes will remain zero
   end;

   {
		Xor key with ipad and ipod constants
			iKeyPad = key xor 0x36
			oKeyPad = key xor 0x5c

		TODO: Unroll this to blockSize div 4 xor's of $5c5c5c5c and $36363636
	}
   for i := 0 to blockSize-1 do
   begin
      oKeyPad[i] := oKeyPad[i] xor $5c;
      iKeyPad[i] := iKeyPad[i] xor $36;
   end;

	{
		Result := hash(oKeyPad || hash(iKeyPad || message))
	}
   // Perform inner hash: digest = Hash(iKeyPad || data)
	SetLength(iKeyPad, blockSize+DataLen);
	Move(data, iKeyPad[blockSize], DataLen);
	Hash.HashData(iKeyPad[0], Length(iKeyPad));
	digest := Hash.Finalize;

   // perform outer hash: result = Hash(oKeyPad || digest)
	SetLength(oKeyPad, blockSize+Length(digest));
	Move(digest[0], oKeyPad[blockSize], Length(digest));
	Hash.HashData(oKeyPad[0], Length(oKeyPad));
	Result := Hash.Finalize;
end;

function TScrypt.Integerify(const B: array of Byte; const N: Integer): Integer;
begin
{
		Integerify (B[0] ... B[2 * r - 1]) is defined
		as the result of interpreting B[2 * r - 1] as a
		little-endian integer.
}

end;

function TScrypt.PBKDF2(const Hash: IHashAlgorithm; const Password: UnicodeString; const Salt; const SaltLength: Integer;
		IterationCount, DesiredBytes: Integer): TBytes;
var
	Ti: TBytes;
	V: TBytes;
	U: TBytes;
	hLen: Integer; //HMAC size in bytes
	cbSalt: Integer;
	l, r, i, j: Integer;
	dwULen: DWORD;
	derivedKey: TBytes;
	utf8Password: TBytes;
begin
	{
		Password-Based Key Derivation Function 2

		Implementation of RFC2898
				PKCS #5: Password-Based Cryptography Specification Version 2.0
				http://tools.ietf.org/html/rfc2898

		Given an arbitrary "password" string, and optionally some salt, PasswordKeyDeriveBytes
		can generate n bytes, suitable for use as a cryptographic key.

		e.g. AES commonly uses 128-bit (16 byte) or 256-bit (32 byte) keys.

		Tested with test vectors from RFC6070
				PKCS #5: Password-Based Key Derivation Function 2 (PBKDF2)  Test Vectors
				http://tools.ietf.org/html/rfc6070
	}
//	if DerivedKeyLength > 2^32*hLen then
//		raise Exception.Create('Derived key too long');

	hLen := Hash.DigestSize;

	l := Ceil(DesiredBytes / hLen);
	r := DesiredBytes - (l-1)*hLen;

	cbSalt := SaltLength;

	SetLength(Ti, hLen);
	SetLength(V,  hLen);
	SetLength(U,  Max(cbSalt+4, hLen));

	SetLength(derivedKey, DesiredBytes);

	utf8Password := Self.StringToBytes(Password);

	for i := 1 to l do
	begin
		ZeroMemory(@Ti[0], hLen);
		for j := 1 to IterationCount do
		begin
			if j = 1 then
			begin
				//It's the first iteration, construct the input for the hmac function
				if cbSalt > 0 then
					Move(Salt, u[0], cbSalt);
				U[cbSalt]    := Byte((i and $FF000000) shr 24);
				U[cbSalt+ 1] := Byte((i and $00FF0000) shr 16);
				U[cbSalt+ 2] := Byte((i and $0000FF00) shr  8);
				U[cbSalt+ 3] := Byte((i and $000000FF)       );
				dwULen := cbSalt + 4;
			end
			else
			begin
				Move(V[0], U[0], hLen); //memcpy(U, V, hlen);
				dwULen := hLen;
			end;

			//Run Password and U through HMAC to get digest V
			V := Self.HMAC(Hash, utf8Password[0], Length(utf8Password), U[0], dwULen);

			//Ti := Ti xor V

			Self.XorBlockInPlace({var}Ti[0], V[0], hlen);
		end;

		if (i <> l) then
		begin
			Move(Ti[0], derivedKey[(i-1)*hLen], hLen); //memcpy(derivedKey[(i-1) * hlen], Ti, hlen);
		end
		else
		begin
			// Take only the first r bytes
			Move(Ti[0], derivedKey[(i-1)*hLen], r); //memcpy(derivedKey[(i-1) * hlen], Ti, r);
		end;
	end;

	Result := derivedKey;
end;

function TScrypt.ROMix(const B; BlockSize, CostFactor: Cardinal): TBytes;
var
	r: Cardinal;
	N: UInt64;
	X: TBytes;
	V: TBytes;
	i: Cardinal;
	j: UInt64;
	T: TBytes;
const
	SInvalidBlockLength = 'ROMix input is not multiple of 128-bytes';
	SInvalidCostFactorTooLow = 'CostFactor %d must be greater than zero';
	SInvalidCostFactorArgument = 'CostFactor %d must be less than 16r (%d)';
begin
	{
		B: block of r×128 bytes.
		For example, r=5 ==> block size is 5*128 = 640 bytes

			B: [640 bytes]

		Cost: 2^CostFactor. Number of copies of B we will be working with

		For example, CostFactor=3 ==> Cost = 2^3 = 6

			V: [640 bytes][640 bytes][640 bytes][640 bytes][640 bytes][640 bytes]
			      V0         V1         V2         V3         V4         V5

		LiteCoin, for example, uses a blocksize of 128 (r=1)
		and Cost of 1024:

			V: [128][128][128]...[128]    128KB total
			    V0   V1   V2     V1024
	}
	if BlockSize mod 128 <> 0 then
		raise EScryptException.Create(SInvalidBlockLength);
	r := BlockSize div 128;

	{
		Cost (N) = 2^CostFactor (we specify cost factor like BCrypt does, as a the exponent of a two)

		SCrypt rule dictates:

			N < 2^(128*r/8)
			N < 2^(16r)

			2^CostFactor < 2^(16r)

			CostFactor < 16r
	}
	if CostFactor <= 0 then
		raise EScryptException.CreateFmt(SInvalidCostFactorTooLow, [CostFactor]);
	if CostFactor >= (16*r) then
		raise EScryptException.CreateFmt(SInvalidCostFactorArgument, [CostFactor, 16*r]);

	//N ← 2^CostFactor
	N := (1 shl CostFactor);

	//Step 1: X ← B
	SetLength(X, BlockSize);
	Move(B, X[0], BlockSize);

	//Step 2 - Create N copies of B
	//V ← N copies of B
	SetLength(V, BlockSize*N);
	for i := 0 to N-1 do
	begin
		//V[i] ← X
		Move(X[0], V[BlockSize*i], BlockSize);

		//X ← BlockMix(X)
		X := Self.BlockMix(X); //first iteration values match the BlockMix test vectors
	end;

	//Step 3
	SetLength(T, BlockSize);
	for i := 0 to N-1 do
	begin
		//j ← Integerify(X) mod N

		//Convert first 8-bytes of the *last* 64-byte block of X to a UInt64, assuming little endian (Intel) format
		j := PUInt64(@X[BlockSize-64])^; //0xE2B6E8D50510A964 = 16,336,500,699,943,709,028
		j := j mod N; //4

		//T ← X xor V[j]
		//X ← BlockMix(T)
		Move(V[BlockSize*j], T[0], BlockSize);
		XorBlockInPlace(T[0], X[0], BlockSize);
		X := Self.BlockMix(T);
	end;

	Result := X;
end;

function TScrypt.Salsa20(const Input): TBytes;
var
	i: Integer;
	X: array[0..15] of LongWord;
	inArr, outArr: PLongWordArray;
begin
	//X ← Input;
	inArr := PLongWordArray(@Input);
	for i := 0 to 15 do
		X[i] := inArr[i]; //ByteSwap(inArr[i]);

	for i := 1 to 4  do
	begin
		x[ 4] := x[ 4] xor LRot32(x[ 0]+x[12], 7);  x[ 8] := x[ 8] xor LRot32(x[ 4]+x[ 0], 9);
		x[12] := x[12] xor LRot32(x[ 8]+x[ 4],13);  x[ 0] := x[ 0] xor LRot32(x[12]+x[ 8],18);
		x[ 9] := x[ 9] xor LRot32(x[ 5]+x[ 1], 7);  x[13] := x[13] xor LRot32(x[ 9]+x[ 5], 9);
		x[ 1] := x[ 1] xor LRot32(x[13]+x[ 9],13);  x[ 5] := x[ 5] xor LRot32(x[ 1]+x[13],18);
		x[14] := x[14] xor LRot32(x[10]+x[ 6], 7);  x[ 2] := x[ 2] xor LRot32(x[14]+x[10], 9);
		x[ 6] := x[ 6] xor LRot32(x[ 2]+x[14],13);  x[10] := x[10] xor LRot32(x[ 6]+x[ 2],18);
		x[ 3] := x[ 3] xor LRot32(x[15]+x[11], 7);  x[ 7] := x[ 7] xor LRot32(x[ 3]+x[15], 9);
		x[11] := x[11] xor LRot32(x[ 7]+x[ 3],13);  x[15] := x[15] xor LRot32(x[11]+x[ 7],18);
		x[ 1] := x[ 1] xor LRot32(x[ 0]+x[ 3], 7);  x[ 2] := x[ 2] xor LRot32(x[ 1]+x[ 0], 9);
		x[ 3] := x[ 3] xor LRot32(x[ 2]+x[ 1],13);  x[ 0] := x[ 0] xor LRot32(x[ 3]+x[ 2],18);
		x[ 6] := x[ 6] xor LRot32(x[ 5]+x[ 4], 7);  x[ 7] := x[ 7] xor LRot32(x[ 6]+x[ 5], 9);
		x[ 4] := x[ 4] xor LRot32(x[ 7]+x[ 6],13);  x[ 5] := x[ 5] xor LRot32(x[ 4]+x[ 7],18);
		x[11] := x[11] xor LRot32(x[10]+x[ 9], 7);  x[ 8] := x[ 8] xor LRot32(x[11]+x[10], 9);
		x[ 9] := x[ 9] xor LRot32(x[ 8]+x[11],13);  x[10] := x[10] xor LRot32(x[ 9]+x[ 8],18);
		x[12] := x[12] xor LRot32(x[15]+x[14], 7);  x[13] := x[13] xor LRot32(x[12]+x[15], 9);
		x[14] := x[14] xor LRot32(x[13]+x[12],13);  x[15] := x[15] xor LRot32(x[14]+x[13],18);
   end;

	//Result ← Input + X;
	SetLength(Result, 64); //64 bytes
	outArr := PLongWordArray(@Result[0]);

	i := 0;
	while (i <= 15) do
	begin
		outArr[i  ] := X[i  ] + inArr[i  ];
		outArr[i+1] := X[i+1] + inArr[i+1];
		outArr[i+2] := X[i+2] + inArr[i+2];
		outArr[i+3] := X[i+3] + inArr[i+3];
//		outArr[i  ] := ByteSwap(X[i  ] + ByteSwap(inArr[i  ]));
//		outArr[i+1] := ByteSwap(X[i+1] + ByteSwap(inArr[i+1]));
//		outArr[i+2] := ByteSwap(X[i+2] + ByteSwap(inArr[i+2]));
//		outArr[i+3] := ByteSwap(X[i+3] + ByteSwap(inArr[i+3]));
		Inc(i, 4);
   end;
end;

procedure TScrypt.Salsa20InPlace(var Input);
var
	X: array[0..15] of LongWord;
	i: Integer;
	Result: PLongWordArray;
begin
{
	The 64-byte input x to Salsa20 is viewed in little-endian form as 16 UInt32's
}
	//Copy 64-byte input array into UInt32 array
	for i := 0 to 15 do
		X[i] := PLongWordArray(@Input)^[i];

	//The guy who originally authored Salsa said it is a 10-round algorithm,
	//but thought it would be hilarious to for i = 1 to 10 stepping by two.
	//So it's a five round function.
	//The guy who authored scrypt calls it an 8-round algorithm,
	//but kept up the joke, and also skipping by two; so it's a four-round algorithm.
	//The stupidity stops here: it's a four round algorithm: for i = 1 to 4
	for i := 1 to 4 do
	begin
		x[ 4] := x[ 4] xor LRot32(x[ 0]+x[12], 7);  x[ 8] := x[ 8] xor LRot32(x[ 4]+x[ 0], 9);
		x[12] := x[12] xor LRot32(x[ 8]+x[ 4],13);  x[ 0] := x[ 0] xor LRot32(x[12]+x[ 8],18);
		x[ 9] := x[ 9] xor LRot32(x[ 5]+x[ 1], 7);  x[13] := x[13] xor LRot32(x[ 9]+x[ 5], 9);
		x[ 1] := x[ 1] xor LRot32(x[13]+x[ 9],13);  x[ 5] := x[ 5] xor LRot32(x[ 1]+x[13],18);
		x[14] := x[14] xor LRot32(x[10]+x[ 6], 7);  x[ 2] := x[ 2] xor LRot32(x[14]+x[10], 9);
		x[ 6] := x[ 6] xor LRot32(x[ 2]+x[14],13);  x[10] := x[10] xor LRot32(x[ 6]+x[ 2],18);
		x[ 3] := x[ 3] xor LRot32(x[15]+x[11], 7);  x[ 7] := x[ 7] xor LRot32(x[ 3]+x[15], 9);
		x[11] := x[11] xor LRot32(x[ 7]+x[ 3],13);  x[15] := x[15] xor LRot32(x[11]+x[ 7],18);
		x[ 1] := x[ 1] xor LRot32(x[ 0]+x[ 3], 7);  x[ 2] := x[ 2] xor LRot32(x[ 1]+x[ 0], 9);
		x[ 3] := x[ 3] xor LRot32(x[ 2]+x[ 1],13);  x[ 0] := x[ 0] xor LRot32(x[ 3]+x[ 2],18);
		x[ 6] := x[ 6] xor LRot32(x[ 5]+x[ 4], 7);  x[ 7] := x[ 7] xor LRot32(x[ 6]+x[ 5], 9);
		x[ 4] := x[ 4] xor LRot32(x[ 7]+x[ 6],13);  x[ 5] := x[ 5] xor LRot32(x[ 4]+x[ 7],18);
		x[11] := x[11] xor LRot32(x[10]+x[ 9], 7);  x[ 8] := x[ 8] xor LRot32(x[11]+x[10], 9);
		x[ 9] := x[ 9] xor LRot32(x[ 8]+x[11],13);  x[10] := x[10] xor LRot32(x[ 9]+x[ 8],18);
		x[12] := x[12] xor LRot32(x[15]+x[14], 7);  x[13] := x[13] xor LRot32(x[12]+x[15], 9);
		x[14] := x[14] xor LRot32(x[13]+x[12],13);  x[15] := x[15] xor LRot32(x[14]+x[13],18);
   end;

	//Result := Input + X;
	Result := PLongWordArray(@Input);
	i := 0;
	while (i < 15) do
	begin
		Result[i  ] := Result[i  ] + X[i  ];
		Result[i+1] := Result[i+1] + X[i+1];
		Result[i+2] := Result[i+2] + X[i+2];
		Result[i+3] := Result[i+3] + X[i+3];
		Inc(i, 4);
   end;
end;

function TScrypt.StringToBytes(const s: string): TBytes;
begin
{
	For scrypt passwords we will use UTF-8 encoding.
}
	Result := TEncoding.UTF8.GetBytes(s);
end;

procedure TScrypt.XorBlockInPlace(var A; const B; Length: Integer);
var
	i: Integer;
begin
	//TODO: Unroll to 4-byte chunks
	for i := 0 to Length-1 do
	begin
		PByteArray(@A)[i] := PByteArray(@A)[i] xor PByteArray(@B)[i];
   end;
end;

{ TSHA1 }

constructor TSHA1.Create;
begin
	inherited Create;

	Initialize;
end;

function TSHA1.Finalize: TBytes;
begin
	Result := Self.HashFinal;
//	Self.Initialize; HashFinal does the burn
end;

procedure TSHA1.Burn;
begin
	//Empty the hash buffer
	FHashLength.QuadPart := 0;
	FHashBufferIndex := 0;
	FillChar(FHashBuffer[0], Length(FHashBuffer), 0);

	//And the current state of the hash
	FABCDEBuffer[0] := $67452301;
	FABCDEBuffer[1] := $EFCDAB89;
	FABCDEBuffer[2] := $98BADCFE;
	FABCDEBuffer[3] := $10325476;
	FABCDEBuffer[4] := $C3D2E1F0;

	FInitialized := True;
end;

procedure TSHA1.Compress;
{Call this when the HashBuffer is full, and can now be dealt with}
var
	A, B, C, D, E: LongWord;  //temporary buffer storage#1
	TEMP: LongWord;  //temporary buffer for a single Word
	W: array[0..79] of LongWord;  //temporary buffer storage#2
	tCount: integer;  //counter
begin
	{Reset HashBuffer index since it can now be reused
		(well, not _now_, but after .Compress}
	FHashBufferIndex := 0;

	{Move HashBuffer into W, and change the Endian order}
	Move(FHashBuffer[0], W[0], SizeOf(FHashBuffer) );
	for tCount := 0 to 15 do
		W[tCount] := ByteSwap(W[tCount]);

	{Step B in 'FIPS PUB 180-1'
	 - Calculate the rest of Wt}
	for tCount := 16 to 79 do
		W[tCount]:= LRot32(W[tCount-3] xor W[tCount-8] xor W[tCount-14] xor W[tCount-16],1);

	{Step C in 'FIPS PUB 180-1'
	 - Copy the CurrentHash into the ABCDE buffer}
	A := FABCDEBuffer[0];
	B := FABCDEBuffer[1];
	C := FABCDEBuffer[2];
	D := FABCDEBuffer[3];
	E := FABCDEBuffer[4];

	{Step D in 'FIPS PUB 180-1}
	{t=0..19 uses fa}
	for tCount:= 0 to 19 do
	begin
	{$Q-}
		TEMP :=
				LRot32(A, 5) +
				(D xor (B and (C xor D))) +
				E + W[tCount] + $5A827999;
		E := D;
		D := C;
		C := LRot32(B, 30);
		B := A;
		A := TEMP;
	end;

	{t=20..39 uses fb}
	for tCount := 20 to 39 do
	begin
	{$Q-}
		TEMP :=
				LRot32(A, 5) +
				(B xor C xor D) +
				E + W[tCount] + $6ED9EBA1;
		E := D;
		D := C;
		C := LRot32(B, 30);
		B := A;
		A := TEMP;
	end;

	{t=40..59 uses fc}
	for tCount := 40 to 59 do
	begin
	{$Q-}
		TEMP :=
				LRot32(A, 5) +
				((B and C) or (D and (B or C)))+
				E + W[tCount] + $8F1BBCDC;
		E := D;
		D := C;
		C := LRot32(B, 30);
		B := A;
		A := TEMP;
	end;

	{t60..79 uses fd}
	for tCount := 60 to 79 do
	begin
	{$Q-}
		TEMP :=
				LRot32(A, 5) +
				(B xor C xor D) +
				E + W[tCount] + $CA62C1D6;
		E := D;
		D := C;
		C := LRot32(B, 30);
		B := A;
		A := TEMP;
	end;

	{Step E in 'FIPS PUB 180-1'
	 - Update the Current hash values}
	FABCDEBuffer[0] := FABCDEBuffer[0] + A;
	FABCDEBuffer[1] := FABCDEBuffer[1] + B;
	FABCDEBuffer[2] := FABCDEBuffer[2] + C;
	FABCDEBuffer[3] := FABCDEBuffer[3] + D;
	FABCDEBuffer[4] := FABCDEBuffer[4] + E;

	{Clear out W and the HashBuffer}
	FillChar(W[0], SizeOf(W), 0);
	FillChar(FHashBuffer[0], SizeOf(FHashBuffer), 0);
end;

function TSHA1.GetBlockSize: Integer;
begin
	Result := 64; //block size of SHA1 is 64 bytes (512 bits)
end;

function TSHA1.GetDigestSize: Integer;
begin
	Result := 20; //SHA-1 digest size is 160 bits (20 bytes)
end;

procedure TSHA1.HashCore(const Data; DataLen: Integer);
//	Updates the state of the hash object so a correct hash value is returned at
//	the end of the data stream.
var
	bytesRemainingInHashBuffer: Integer;
	dummySize: Integer;
	buffer: PByteArray;
	dataOffset: Integer;
begin
{	Parameters
	array		input for which to compute the hash code.
	ibStart	offset into the byte array from which to begin using data.
	cbSize	number of bytes in the byte array to use as data.}
	if not FInitialized then
		raise EScryptException.Create('SHA1 not initialized');

	if (DataLen = 0) then
		Exit;

	buffer := PByteArray(@Data);
	dataOffset := 0;

	dummySize := DataLen;
	UpdateLen(dummySize);  //Update the Len variables given size

	while dummySize > 0 do
	begin
		bytesRemainingInHashBuffer := Length(FHashBuffer) - FHashBufferIndex;
		{HashBufferIndex is the next location to write to in hashbuffer
			Sizeof(HasBuffer) - HashBufferIndex = space left in HashBuffer}
		{cbSize is the number of bytes coming in from the user}
		if bytesRemainingInHashBuffer <= dummySize then
		begin
			{If there is enough data left in the buffer to fill the HashBuffer
				then copy enough to fill the HashBuffer}
			Move(buffer[dataOffset], FHashBuffer[FHashBufferIndex], bytesRemainingInHashBuffer);
			Dec(dummySize, bytesRemainingInHashBuffer);
			Inc(dataOffset, bytesRemainingInHashBuffer);
			Compress;
		end
		else
		begin
{ 20070508  Ian Boyd
		If the input length was not an even multiple of HashBufferSize (64 bytes i think), then
			there was a buffer overrun. Rather than Moving and incrementing by DummySize
			it was using cbSize, which is the size of the original buffer}

			{If there isn't enough data to fill the HashBuffer...}
			{...copy as much as possible from the buffer into HashBuffer...}
			Move(buffer[dataOffset], FHashBuffer[FHashBufferIndex], dummySize);
			{then move the HashBuffer Index to the next empty spot in HashBuffer}
			Inc(FHashBufferIndex, dummySize);
			{And shrink the size in the buffer to zero}
			dummySize := 0;
		end;
	end;
end;

procedure TSHA1.HashData(const Buffer; BufferLen: Integer);
begin
	Self.HashCore(Buffer, BufferLen);
end;

function TSHA1.HashFinal: TBytes;
{	This method finalizes any partial computation and returns the correct hash
	value for the data stream.}
type
	TLongWordBuffer = array[0..15] of LongWord;
begin
	{The final act is to tack on the size of the message}

	{Tack on the final bit 1 to the end of the data}
	FHashBuffer[FHashBufferIndex] := $80;

	{[56] is the start of the 2nd last word in HashBuffer}
	{if we are at (or past) it, then there isn't enough room for the whole
		message length (64-bits i.e. 2 words) to be added in}
	{The HashBuffer can essentially be considered full (even if the Index is not
	  all the way to the end), since it the remaining zeros are prescribed padding
	  anyway}
	if FHashBufferIndex >= 56 then
		Compress;

	{Write in LenHi (it needs it's endian order changed)}
	{LenHi is the high order word of the Length of the message in bits}
	TLongWordBuffer(FHashBuffer)[14] := ByteSwap(FHashLength.HighPart);

	{[60] is the last word in HashBuffer}
	{Write in LenLo (it needs it's endian order changed)}
	{LenLo is the low order word of the length of the message}
	TLongWordBuffer(FHashBuffer)[15] := ByteSwap(FHashLength.LowPart);

	{The hashbuffer should now be filled up}
	Compress;

	{Finalize the hash value into CurrentHash}
	SetLength(Result, Self.GetDigestSize);
	TLongWordDynArray(Result)[0] := ByteSwap(FABCDEBuffer[0]);
	TLongWordDynArray(Result)[1] := ByteSwap(FABCDEBuffer[1]);
	TLongWordDynArray(Result)[2] := ByteSwap(FABCDEBuffer[2]);
	TLongWordDynArray(Result)[3] := ByteSwap(FABCDEBuffer[3]);
	TLongWordDynArray(Result)[4] := ByteSwap(FABCDEBuffer[4]);

	{Burn all the temporary areas}
	Burn;
end;

procedure TSHA1.Initialize;
begin
	Self.Burn;
end;

procedure TSHA1.SelfTest;
begin
	//call the selftest contained in the other unit
end;

procedure TSHA1.UpdateLen(NumBytes: LongWord);
//Len is the number of bytes in input buffer
//This is eventually used to pad out the final message block with
//   the number of bits in the block (a 64-bit number)
begin
	//the HashLength is in BITS, so multiply NumBytes by 8
	Inc(FHashLength.QuadPart, NumBytes * 8);
end;

{ TSHA2_256 }

procedure TSHA256.Burn;
begin
	FHashLength.QuadPart := 0;

	FillChar(FHashBuffer[0], Length(FHashBuffer), 0);
	FHashBufferIndex := 0;

	FCurrentHash[0] := $6a09e667;
	FCurrentHash[1] := $bb67ae85;
	FCurrentHash[2] := $3c6ef372;
	FCurrentHash[3] := $a54ff53a;
	FCurrentHash[4] := $510e527f;
	FCurrentHash[5] := $9b05688c;
	FCurrentHash[6] := $1f83d9ab;
	FCurrentHash[7] := $5be0cd19;

	FInitialized := True;
end;

procedure TSHA256.Compress;
{Call this when the HashBuffer is full, and can now be dealt with}
var
	a, b, c, d, e, f, g, h: LongWord;  //temporary buffer storage#1
	t: Integer;
	s0, s1, ch, maj: LongWord;
	temp1, temp2: LongWord;  //temporary buffer for a single Word
	W: array[0..79] of LongWord;  //temporary buffer storage#2
//	tCount: integer;  //counter

const
	K: array[0..63] of LongWord = (
			$428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
			$d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
			$e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
			$983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
			$27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
			$a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
			$19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
			$748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2
	);

begin
	{1. Prepare the message schedule W from the block we're processing. Start with the first 16 bytes}
	//Move(FHashBuffer[0], W[0], SizeOf(FHashBuffer) );
	for t := 0 to 15 do
	begin
   	W[t] := ByteSwap(PLongWord(@FHashBuffer[t*4])^);
//		W[tCount] := ByteSwap(W[tCount]);
	end;

	{ Calculate the rest of W (16..79) }
	for t := 16 to 79 do
	begin
		s0 := RRot32(W[t-15],  7) xor RRot32(W[t-15], 18) xor (W[t-15] shr  3); //σ₀(W[t-15]);
		s1 := RRot32(W[t- 2], 17) xor RRot32(W[t- 2], 19) xor (W[t- 2] shr 10); //σ₁(W[t-2]);
		W[t]:= W[t-16] + s0 + W[t-7] + s1;
	end;

	{2.  Initialize working variables a..h by copying CurrentHash into working variables }
	a := FCurrentHash[0];
	b := FCurrentHash[1];
	c := FCurrentHash[2];
	d := FCurrentHash[3];
	e := FCurrentHash[4];
	f := FCurrentHash[5];
	g := FCurrentHash[6];
	h := FCurrentHash[7];

	{3. }
	for t := 0 to 63 do
	begin
	{$Q-}
		S1 := RRot32(e, 6) xor RRot32(e, 11) xor RRot32(e, 25); //Σ₁(e)
		ch :=  (e and f) xor ((not e) and g); //Choose(e,f,g)
		temp1 := h + S1 + ch + K[t] + W[t];
		S0 := RRot32(a, 2) xor RRot32(a, 13) xor RRot32(a, 22); //Σ₀(a)
		maj := (a and b) xor (a and c) xor (b and c); //Majority(a,b,c)
		temp2 := S0 + maj;

		h := g;
		g := f;
		f := e;
		e := d + temp1;
		d := c;
		c := b;
		b := a;
		a := temp1 + temp2;
	end;

	{ Update the current hash values}
	FCurrentHash[0] := FCurrentHash[0] + a;
	FCurrentHash[1] := FCurrentHash[1] + b;
	FCurrentHash[2] := FCurrentHash[2] + c;
	FCurrentHash[3] := FCurrentHash[3] + d;
	FCurrentHash[4] := FCurrentHash[4] + e;
	FCurrentHash[5] := FCurrentHash[5] + f;
	FCurrentHash[6] := FCurrentHash[6] + g;
	FCurrentHash[7] := FCurrentHash[7] + h;

	{Reset HashBuffer index since it can now be reused}
	FHashBufferIndex := 0;
	FillChar(FHashBuffer[0], Length(FHashBuffer), 0); //empty the buffer for the next set of writes
end;

constructor TSHA256.Create;
begin
	inherited Create;

	Initialize;
end;

function TSHA256.Finalize: TBytes;
begin
	Result := Self.HashFinal;
//	Self.Initialize; HashFinal does the burn and reset
end;

function TSHA256.GetBlockSize: Integer;
begin
	Result := 64; //block size of SHA2-256 is 512 bits
end;

function TSHA256.GetDigestSize: Integer;
begin
	Result := 32; //digest size of SHA2-256 is 256 bits (32 bytes)
end;

procedure TSHA256.HashCore(const Data; DataLen: Integer);
//	Updates the state of the hash object so a correct hash value is returned at
//	the end of the data stream.
var
	bytesRemainingInHashBuffer: Integer;
	dummySize: Integer;
	buffer: PByteArray;
	dataOffset: Integer;
begin
{	Parameters
	array		input for which to compute the hash code.
	ibStart	offset into the byte array from which to begin using data.
	cbSize	number of bytes in the byte array to use as data.}
	if not FInitialized then
		raise EScryptException.Create('SHA1 not initialized');

	if (DataLen = 0) then
		Exit;

	buffer := PByteArray(@Data);
	dataOffset := 0;

	dummySize := DataLen;
	UpdateLen(dummySize);  //Update the Len variables given size

	while dummySize > 0 do
	begin
		bytesRemainingInHashBuffer := Length(FHashBuffer) - FHashBufferIndex;
		{HashBufferIndex is the next location to write to in hashbuffer
			Sizeof(HasBuffer) - HashBufferIndex = space left in HashBuffer}
		{cbSize is the number of bytes coming in from the user}
		if bytesRemainingInHashBuffer <= dummySize then
		begin
			{If there is enough data left in the buffer to fill the HashBuffer
				then copy enough to fill the HashBuffer}
			Move(buffer[dataOffset], FHashBuffer[FHashBufferIndex], bytesRemainingInHashBuffer);
			Dec(dummySize, bytesRemainingInHashBuffer);
			Inc(dataOffset, bytesRemainingInHashBuffer);
			Compress;
		end
		else
		begin
{ 20070508  Ian Boyd
		If the input length was not an even multiple of HashBufferSize (64 bytes i think), then
			there was a buffer overrun. Rather than Moving and incrementing by DummySize
			it was using cbSize, which is the size of the original buffer}

			{If there isn't enough data to fill the HashBuffer...}
			{...copy as much as possible from the buffer into HashBuffer...}
			Move(buffer[dataOffset], FHashBuffer[FHashBufferIndex], dummySize);
			{then move the HashBuffer Index to the next empty spot in HashBuffer}
			Inc(FHashBufferIndex, dummySize);
			{And shrink the size in the buffer to zero}
			dummySize := 0;
		end;
	end;
end;

procedure TSHA256.HashData(const Buffer; BufferLen: Integer);
begin
	Self.HashCore(Buffer, BufferLen);
end;

function TSHA256.HashFinal: TBytes;
{	This method finalizes any partial computation and returns the correct hash
	value for the data stream.}
type
	TLongWordBuffer = array[0..15] of LongWord;
begin
	{The final act is to tack on the size of the message}

	{Tack on the final bit 1 to the end of the data}
	FHashBuffer[FHashBufferIndex] := $80;

	{[56] is the start of the 2nd last word in HashBuffer}
	{if we are at (or past) it, then there isn't enough room for the whole
		message length (64-bits i.e. 2 words) to be added in}
	{The HashBuffer can essentially be considered full (even if the Index is not
	  all the way to the end), since it the remaining zeros are prescribed padding
	  anyway}
	if FHashBufferIndex >= 56 then
		Compress;

	{Write in LenHi (it needs it's endian order changed)}
	{LenHi is the high order word of the Length of the message in bits}
	TLongWordBuffer(FHashBuffer)[14] := ByteSwap(FHashLength.HighPart);

	{[60] is the last word in HashBuffer}
	{Write in LenLo (it needs it's endian order changed)}
	{LenLo is the low order word of the length of the message}
	TLongWordBuffer(FHashBuffer)[15] := ByteSwap(FHashLength.LowPart);

	{The hashbuffer should now be filled up}
	Compress;

	{Finalize the hash value into CurrentHash}
	SetLength(Result, Self.GetDigestSize);
	TLongWordDynArray(Result)[0]:= ByteSwap(FCurrentHash[0]);
	TLongWordDynArray(Result)[1]:= ByteSwap(FCurrentHash[1]);
	TLongWordDynArray(Result)[2]:= ByteSwap(FCurrentHash[2]);
	TLongWordDynArray(Result)[3]:= ByteSwap(FCurrentHash[3]);
	TLongWordDynArray(Result)[4]:= ByteSwap(FCurrentHash[4]);
	TLongWordDynArray(Result)[5]:= ByteSwap(FCurrentHash[5]);
	TLongWordDynArray(Result)[6]:= ByteSwap(FCurrentHash[6]);
	TLongWordDynArray(Result)[7]:= ByteSwap(FCurrentHash[7]);

	{Burn all the temporary areas}
	Burn;
end;

procedure TSHA256.Initialize;
begin
	Self.Burn;

	FInitialized := True;
end;

procedure TSHA256.UpdateLen(NumBytes: LongWord);
//Len is the number of bytes in input buffer
//This is eventually used to pad out the final message block with
//   the number of bits in the block (a 64-bit number)
begin
	//the HashLength is in BITS, so multiply NumBytes by 8
	Inc(FHashLength.QuadPart, NumBytes * 8);
end;

{ TSHA256CryptoServiceProvider }

const
	advapi32 = 'advapi32.dll';
const
	PROV_RSA_AES = 24; //Provider type; from WinCrypt.h
	MS_ENH_RSA_AES_PROV_W: UnicodeString = 'Microsoft Enhanced RSA and AES Cryptographic Provider'; //Provider name
	MS_ENH_RSA_AES_PROV_XP_W: UnicodeString = 'Microsoft Enhanced RSA and AES Cryptographic Provider (Prototype)'; //Provider name
	// dwFlags definitions for CryptAcquireContext
	CRYPT_VERIFYCONTEXT = $F0000000;

	// dwParam
	KP_IV = 		1;  // Initialization vector
	KP_MODE = 	4;  // Mode of the cipher

	// KP_MODE
	CRYPT_MODE_CBC = 			1;       // Cipher block chaining
	CRYPT_MODE_ECB = 			2;       // Electronic code book
	CRYPT_MODE_OFB = 			3;       // Output feedback mode
	CRYPT_MODE_CFB = 			4;       // Cipher feedback mode
	CRYPT_MODE_CTS = 			5;       // Ciphertext stealing mode
	CRYPT_MODE_CBCI = 		6;   // ANSI CBC Interleaved
	CRYPT_MODE_CFBP = 		7;   // ANSI CFB Pipelined
	CRYPT_MODE_OFBP = 		8;   // ANSI OFB Pipelined
	CRYPT_MODE_CBCOFM = 		9;   // ANSI CBC + OF Masking
	CRYPT_MODE_CBCOFMI = 	10;  // ANSI CBC + OFM Interleaved

	HP_HASHVAL = 				$0002;
	HP_HASHSIZE = 				$0004;

	PLAINTEXTKEYBLOB = $8;
	CUR_BLOB_VERSION = 2;

	ALG_CLASS_DATA_ENCRYPT = 	(3 shl 13);
	ALG_TYPE_BLOCK = 				(3 shl 9);
	ALG_SID_AES_128 = 			14;
	ALG_SID_AES_256 = 			16;

	CALG_AES_128 = (ALG_CLASS_DATA_ENCRYPT or ALG_TYPE_BLOCK or ALG_SID_AES_128);
	CALG_AES_256 = (ALG_CLASS_DATA_ENCRYPT or ALG_TYPE_BLOCK or ALG_SID_AES_256);
	CALG_SHA1 = $00008004;
	CALG_SHA_256 = $0000800c;

function CryptAcquireContext(out phProv: HCRYPTPROV; pszContainer: PWideChar; pszProvider: PWideChar; dwProvType: DWORD; dwFlags: DWORD): BOOL; stdcall; external advapi32 name 'CryptAcquireContextW';
function CryptReleaseContext(hProv: HCRYPTPROV; dwFlags: DWORD): BOOL; stdcall; external advapi32;
function CryptGenRandom(hProv: HCRYPTPROV; dwLen: DWORD; pbBuffer: Pointer): BOOL; stdcall; external advapi32;
function CryptCreateHash(hProv: HCRYPTPROV; Algid: ALG_ID; hKey: HCRYPTKEY; dwFlags: DWORD; out hHash: HCRYPTHASH): BOOL; stdcall; external advapi32;
function CryptHashData(hHash: HCRYPTHASH; pbData: PByte; dwDataLen: DWORD; dwFlags: DWORD): BOOL; stdcall; external advapi32;
function CryptGetHashParam(hHash: HCRYPTHASH; dwParam: DWORD; pbData: PByte; var dwDataLen: DWORD; dwFlags: DWORD): BOOL; stdcall; external advapi32;
function CryptDestroyHash(hHash: HCRYPTHASH): BOOL; stdcall; external advapi32;

//function CryptImportKey(hProv: HCRYPTPROV; pbData: PByte; dwDataLen: DWORD; hPubKey: HCRYPTKEY; dwFlags: DWORD; out phKey: HCRYPTKEY): BOOL; stdcall; external advapi32;
//function CryptSetKeyParam(hKey: HCRYPTKEY; dwParam: DWORD; pbData: PByte; dwFlags: DWORD): BOOL; stdcall; external advapi32;
//function CryptDestroyKey(hKey: HCRYPTKEY): BOOL; stdcall; external advapi32;
//function CryptEncrypt(hKey: HCRYPTKEY; hHash: HCRYPTHASH; Final: BOOL; dwFlags: DWORD; pbData: PByte; var pdwDataLen: DWORD; dwBufLen: DWORD): BOOL; stdcall; external advapi32;
//function CryptDecrypt(hKey: HCRYPTKEY; hHash: HCRYPTHASH; Final: BOOL; dwFlags: DWORD; pbData: PByte; var pdwDataLen: DWORD): BOOL; stdcall; external advapi32;


procedure TSHA256csp.Burn;
var
	le: DWORD;
begin
	if FHash = 0 then
		Exit;

	try
		if not CryptDestroyHash(FHash) then
		begin
	     	le := GetLastError;
			RaiseOSError(le, Format('Could not destroy current hash provider: %s (%d)', [SysErrorMessage(le), le]));
			Exit;
		end;
	finally
		FHash := 0;
   end;
end;

constructor TSHA256csp.Create;
var
	providerName: UnicodeString;
	provider: HCRYPTPROV;
	le: DWORD;
const
	PROV_RSA_AES = 24; //Provider type; from WinCrypt.h
	MS_ENH_RSA_AES_PROV_W: UnicodeString = 'Microsoft Enhanced RSA and AES Cryptographic Provider'; //Provider name
	MS_ENH_RSA_AES_PROV_XP_W: UnicodeString = 'Microsoft Enhanced RSA and AES Cryptographic Provider (Prototype)'; //Provider name

begin
	inherited Create;

	{
		Set ProviderName to either
			providerName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
			providerName = "Microsoft Enhanced RSA and AES Cryptographic Provider (Prototype)"  //Windows XP and earlier
	}
	providerName := MS_ENH_RSA_AES_PROV_W;
	//Before Vista it was a prototype provider
	if (Win32MajorVersion < 6) then //6.0 was Vista and Server 2008
		providerName := MS_ENH_RSA_AES_PROV_XP_W;

//	if not CryptAcquireContext(provider, nil, PWideChar(providerName), PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
	if not CryptAcquireContext(provider, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
	begin
		le := GetLastError;
		RaiseOSError(le, Format('Could not acquire context to provider "%s" (Win32MajorVersion=%d)',
				[providerName, Win32MajorVersion]));
	end;

	FProvider := provider;

	Self.Initialize;
end;

destructor TSHA256csp.Destroy;
begin
	Self.Burn;

	if FProvider <> 0 then
	begin
		CryptReleaseContext(FProvider, 0);
		FProvider := 0;
	end;

  inherited;
end;

function TSHA256csp.Finalize: TBytes;
begin
	Result := Self.HashFinal;
	Self.Initialize;
end;

function TSHA256csp.GetBlockSize: Integer;
begin
	Result := 64; //64-bytes per message block
end;

function TSHA256csp.GetDigestSize: Integer;
begin
	Result := 32; //SHA-256 has a digest size of 32 bytes (256-bits).
end;

procedure TSHA256csp.HashCore(const Data; DataLen: Integer);
var
	le: DWORD;
begin
	if (FHash = 0) then
		raise Exception.Create('TSHA256csp is not initialized');

	if not CryptHashData(FHash, PByte(@Data), DataLen, 0) then
	begin
		le := GetLastError;
		raise Exception.CreateFmt('Error hashing data: %s (%d)', [SysErrorMessage(le), le]);
	end;
end;

procedure TSHA256csp.HashData(const Buffer; BufferLen: Integer);
begin
	Self.HashCore(Buffer, BufferLen);
end;

function TSHA256csp.HashFinal: TBytes;
var
	digestSize: DWORD;
	le: DWORD;
begin
	digestSize := Self.GetDigestSize;
	SetLength(Result, digestSize);

	if not CryptGetHashParam(FHash, HP_HASHVAL, @Result[0], digestSize, 0) then
	begin
		le := GetLastError;
		raise Exception.CreateFmt('Could not get Hash value from CSP: %s (%d)', [SysErrorMessage(le), le]);
   end;
end;

procedure TSHA256csp.Initialize;
var
	le: DWORD;
	hash: THandle;
begin
	Self.Burn;

	if not CryptCreateHash(FProvider, CALG_SHA_256, 0, 0, {out}hash) then
	begin
		le := GetLastError;
		RaiseOSError(le, Format('Could not create CALC_SHA_256 hash: %s (%d)', [SysErrorMessage(le), le]));
		Exit;
	end;

	FHash := hash;
end;

{ TSHA1csp }

procedure TSHA1csp.Burn;
var
	le: DWORD;
begin
	if FHash = 0 then
		Exit;

	try
		if not CryptDestroyHash(FHash) then
		begin
	     	le := GetLastError;
			RaiseOSError(le, Format('Could not destroy current hash provider: %s (%d)', [SysErrorMessage(le), le]));
			Exit;
		end;
	finally
		FHash := 0;
   end;
end;

constructor TSHA1csp.Create;
var
	providerName: UnicodeString;
	provider: HCRYPTPROV;
	le: DWORD;
const
	PROV_RSA_AES = 24; //Provider type; from WinCrypt.h
	MS_ENH_RSA_AES_PROV_W: UnicodeString = 'Microsoft Enhanced RSA and AES Cryptographic Provider'; //Provider name
	MS_ENH_RSA_AES_PROV_XP_W: UnicodeString = 'Microsoft Enhanced RSA and AES Cryptographic Provider (Prototype)'; //Provider name

begin
	inherited Create;

	{
		Set ProviderName to either
			providerName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
			providerName = "Microsoft Enhanced RSA and AES Cryptographic Provider (Prototype)"  //Windows XP and earlier
	}
	providerName := MS_ENH_RSA_AES_PROV_W;
	//Before Vista it was a prototype provider
	if (Win32MajorVersion < 6) then //6.0 was Vista and Server 2008
		providerName := MS_ENH_RSA_AES_PROV_XP_W;

//	if not CryptAcquireContext(provider, nil, PWideChar(providerName), PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
	if not CryptAcquireContext(provider, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
	begin
		le := GetLastError;
		RaiseOSError(le, Format('Could not acquire context to provider "%s" (Win32MajorVersion=%d)',
				[providerName, Win32MajorVersion]));
	end;

	FProvider := provider;

	Self.Initialize;
end;

destructor TSHA1csp.Destroy;
begin
	Self.Burn;

	if FProvider <> 0 then
	begin
		CryptReleaseContext(FProvider, 0);
		FProvider := 0;
	end;

  inherited;
end;

function TSHA1csp.Finalize: TBytes;
begin
	Result := Self.HashFinal;
	Self.Initialize; //Get ready for another round of hashing
end;

function TSHA1csp.GetBlockSize: Integer;
begin
	Result := 64; //block size of SHA1 is 64 bytes (512 bits)
end;

function TSHA1csp.GetDigestSize: Integer;
begin
	Result := 20; //digest size of SHA-1 is 160 bits (20 bytes)
end;

procedure TSHA1csp.HashCore(const Data; DataLen: Integer);
var
	le: DWORD;
begin
	if (FHash = 0) then
		raise Exception.Create('TSHA256csp is not initialized');

	if not CryptHashData(FHash, PByte(@Data), DataLen, 0) then
	begin
		le := GetLastError;
		raise Exception.CreateFmt('Error hashing data: %s (%d)', [SysErrorMessage(le), le]);
	end;
end;

procedure TSHA1csp.HashData(const Buffer; BufferLen: Integer);
begin
	Self.HashCore(Buffer, BufferLen);
end;

function TSHA1csp.HashFinal: TBytes;
var
	digestSize: DWORD;
	le: DWORD;
begin
	digestSize := Self.GetDigestSize;
	SetLength(Result, digestSize);

	if not CryptGetHashParam(FHash, HP_HASHVAL, @Result[0], digestSize, 0) then
	begin
		le := GetLastError;
		raise Exception.CreateFmt('Could not get Hash value from CSP: %s (%d)', [SysErrorMessage(le), le]);
   end;
end;

procedure TSHA1csp.Initialize;
var
	le: DWORD;
	hash: THandle;
begin
	Self.Burn;

	if not CryptCreateHash(FProvider, CALG_SHA1, 0, 0, {out}hash) then
	begin
		le := GetLastError;
		RaiseOSError(le, Format('Could not create CALG_SHA1 hash: %s (%d)', [SysErrorMessage(le), le]));
		Exit;
	end;

	FHash := hash;
end;

end.
