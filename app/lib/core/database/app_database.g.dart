// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $LocalAccountsTable extends LocalAccounts
    with TableInfo<$LocalAccountsTable, LocalAccount> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalAccountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _maskedHintMeta = const VerificationMeta(
    'maskedHint',
  );
  @override
  late final GeneratedColumn<String> maskedHint = GeneratedColumn<String>(
    'masked_hint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isActiveMeta = const VerificationMeta(
    'isActive',
  );
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
    'is_active',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_active" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    maskedHint,
    isActive,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_accounts';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalAccount> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('masked_hint')) {
      context.handle(
        _maskedHintMeta,
        maskedHint.isAcceptableOrUnknown(data['masked_hint']!, _maskedHintMeta),
      );
    } else if (isInserting) {
      context.missing(_maskedHintMeta);
    }
    if (data.containsKey('is_active')) {
      context.handle(
        _isActiveMeta,
        isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LocalAccount map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalAccount(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      maskedHint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}masked_hint'],
      )!,
      isActive: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_active'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LocalAccountsTable createAlias(String alias) {
    return $LocalAccountsTable(attachedDatabase, alias);
  }
}

class LocalAccount extends DataClass implements Insertable<LocalAccount> {
  final String id;
  final String maskedHint;
  final bool isActive;
  final int createdAt;
  final int updatedAt;
  const LocalAccount({
    required this.id,
    required this.maskedHint,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['masked_hint'] = Variable<String>(maskedHint);
    map['is_active'] = Variable<bool>(isActive);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  LocalAccountsCompanion toCompanion(bool nullToAbsent) {
    return LocalAccountsCompanion(
      id: Value(id),
      maskedHint: Value(maskedHint),
      isActive: Value(isActive),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory LocalAccount.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalAccount(
      id: serializer.fromJson<String>(json['id']),
      maskedHint: serializer.fromJson<String>(json['maskedHint']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'maskedHint': serializer.toJson<String>(maskedHint),
      'isActive': serializer.toJson<bool>(isActive),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  LocalAccount copyWith({
    String? id,
    String? maskedHint,
    bool? isActive,
    int? createdAt,
    int? updatedAt,
  }) => LocalAccount(
    id: id ?? this.id,
    maskedHint: maskedHint ?? this.maskedHint,
    isActive: isActive ?? this.isActive,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  LocalAccount copyWithCompanion(LocalAccountsCompanion data) {
    return LocalAccount(
      id: data.id.present ? data.id.value : this.id,
      maskedHint: data.maskedHint.present
          ? data.maskedHint.value
          : this.maskedHint,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalAccount(')
          ..write('id: $id, ')
          ..write('maskedHint: $maskedHint, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, maskedHint, isActive, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalAccount &&
          other.id == this.id &&
          other.maskedHint == this.maskedHint &&
          other.isActive == this.isActive &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class LocalAccountsCompanion extends UpdateCompanion<LocalAccount> {
  final Value<String> id;
  final Value<String> maskedHint;
  final Value<bool> isActive;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const LocalAccountsCompanion({
    this.id = const Value.absent(),
    this.maskedHint = const Value.absent(),
    this.isActive = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalAccountsCompanion.insert({
    required String id,
    required String maskedHint,
    this.isActive = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       maskedHint = Value(maskedHint),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<LocalAccount> custom({
    Expression<String>? id,
    Expression<String>? maskedHint,
    Expression<bool>? isActive,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (maskedHint != null) 'masked_hint': maskedHint,
      if (isActive != null) 'is_active': isActive,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalAccountsCompanion copyWith({
    Value<String>? id,
    Value<String>? maskedHint,
    Value<bool>? isActive,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return LocalAccountsCompanion(
      id: id ?? this.id,
      maskedHint: maskedHint ?? this.maskedHint,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (maskedHint.present) {
      map['masked_hint'] = Variable<String>(maskedHint.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalAccountsCompanion(')
          ..write('id: $id, ')
          ..write('maskedHint: $maskedHint, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CredentialAccountsTable extends CredentialAccounts
    with TableInfo<$CredentialAccountsTable, CredentialAccount> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CredentialAccountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _usernameCiphertextMeta =
      const VerificationMeta('usernameCiphertext');
  @override
  late final GeneratedColumn<Uint8List> usernameCiphertext =
      GeneratedColumn<Uint8List>(
        'username_ciphertext',
        aliasedName,
        false,
        type: DriftSqlType.blob,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _passwordCiphertextMeta =
      const VerificationMeta('passwordCiphertext');
  @override
  late final GeneratedColumn<Uint8List> passwordCiphertext =
      GeneratedColumn<Uint8List>(
        'password_ciphertext',
        aliasedName,
        true,
        type: DriftSqlType.blob,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _schemeMeta = const VerificationMeta('scheme');
  @override
  late final GeneratedColumn<String> scheme = GeneratedColumn<String>(
    'scheme',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    usernameCiphertext,
    passwordCiphertext,
    scheme,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'credential_accounts';
  @override
  VerificationContext validateIntegrity(
    Insertable<CredentialAccount> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('username_ciphertext')) {
      context.handle(
        _usernameCiphertextMeta,
        usernameCiphertext.isAcceptableOrUnknown(
          data['username_ciphertext']!,
          _usernameCiphertextMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_usernameCiphertextMeta);
    }
    if (data.containsKey('password_ciphertext')) {
      context.handle(
        _passwordCiphertextMeta,
        passwordCiphertext.isAcceptableOrUnknown(
          data['password_ciphertext']!,
          _passwordCiphertextMeta,
        ),
      );
    }
    if (data.containsKey('scheme')) {
      context.handle(
        _schemeMeta,
        scheme.isAcceptableOrUnknown(data['scheme']!, _schemeMeta),
      );
    } else if (isInserting) {
      context.missing(_schemeMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId};
  @override
  CredentialAccount map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CredentialAccount(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      usernameCiphertext: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}username_ciphertext'],
      )!,
      passwordCiphertext: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}password_ciphertext'],
      ),
      scheme: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scheme'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $CredentialAccountsTable createAlias(String alias) {
    return $CredentialAccountsTable(attachedDatabase, alias);
  }
}

class CredentialAccount extends DataClass
    implements Insertable<CredentialAccount> {
  final String accountId;
  final Uint8List usernameCiphertext;
  final Uint8List? passwordCiphertext;
  final String scheme;
  final int updatedAt;
  const CredentialAccount({
    required this.accountId,
    required this.usernameCiphertext,
    this.passwordCiphertext,
    required this.scheme,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['username_ciphertext'] = Variable<Uint8List>(usernameCiphertext);
    if (!nullToAbsent || passwordCiphertext != null) {
      map['password_ciphertext'] = Variable<Uint8List>(passwordCiphertext);
    }
    map['scheme'] = Variable<String>(scheme);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  CredentialAccountsCompanion toCompanion(bool nullToAbsent) {
    return CredentialAccountsCompanion(
      accountId: Value(accountId),
      usernameCiphertext: Value(usernameCiphertext),
      passwordCiphertext: passwordCiphertext == null && nullToAbsent
          ? const Value.absent()
          : Value(passwordCiphertext),
      scheme: Value(scheme),
      updatedAt: Value(updatedAt),
    );
  }

  factory CredentialAccount.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CredentialAccount(
      accountId: serializer.fromJson<String>(json['accountId']),
      usernameCiphertext: serializer.fromJson<Uint8List>(
        json['usernameCiphertext'],
      ),
      passwordCiphertext: serializer.fromJson<Uint8List?>(
        json['passwordCiphertext'],
      ),
      scheme: serializer.fromJson<String>(json['scheme']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'usernameCiphertext': serializer.toJson<Uint8List>(usernameCiphertext),
      'passwordCiphertext': serializer.toJson<Uint8List?>(passwordCiphertext),
      'scheme': serializer.toJson<String>(scheme),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  CredentialAccount copyWith({
    String? accountId,
    Uint8List? usernameCiphertext,
    Value<Uint8List?> passwordCiphertext = const Value.absent(),
    String? scheme,
    int? updatedAt,
  }) => CredentialAccount(
    accountId: accountId ?? this.accountId,
    usernameCiphertext: usernameCiphertext ?? this.usernameCiphertext,
    passwordCiphertext: passwordCiphertext.present
        ? passwordCiphertext.value
        : this.passwordCiphertext,
    scheme: scheme ?? this.scheme,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  CredentialAccount copyWithCompanion(CredentialAccountsCompanion data) {
    return CredentialAccount(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      usernameCiphertext: data.usernameCiphertext.present
          ? data.usernameCiphertext.value
          : this.usernameCiphertext,
      passwordCiphertext: data.passwordCiphertext.present
          ? data.passwordCiphertext.value
          : this.passwordCiphertext,
      scheme: data.scheme.present ? data.scheme.value : this.scheme,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CredentialAccount(')
          ..write('accountId: $accountId, ')
          ..write('usernameCiphertext: $usernameCiphertext, ')
          ..write('passwordCiphertext: $passwordCiphertext, ')
          ..write('scheme: $scheme, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    $driftBlobEquality.hash(usernameCiphertext),
    $driftBlobEquality.hash(passwordCiphertext),
    scheme,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CredentialAccount &&
          other.accountId == this.accountId &&
          $driftBlobEquality.equals(
            other.usernameCiphertext,
            this.usernameCiphertext,
          ) &&
          $driftBlobEquality.equals(
            other.passwordCiphertext,
            this.passwordCiphertext,
          ) &&
          other.scheme == this.scheme &&
          other.updatedAt == this.updatedAt);
}

class CredentialAccountsCompanion extends UpdateCompanion<CredentialAccount> {
  final Value<String> accountId;
  final Value<Uint8List> usernameCiphertext;
  final Value<Uint8List?> passwordCiphertext;
  final Value<String> scheme;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const CredentialAccountsCompanion({
    this.accountId = const Value.absent(),
    this.usernameCiphertext = const Value.absent(),
    this.passwordCiphertext = const Value.absent(),
    this.scheme = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CredentialAccountsCompanion.insert({
    required String accountId,
    required Uint8List usernameCiphertext,
    this.passwordCiphertext = const Value.absent(),
    required String scheme,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       usernameCiphertext = Value(usernameCiphertext),
       scheme = Value(scheme),
       updatedAt = Value(updatedAt);
  static Insertable<CredentialAccount> custom({
    Expression<String>? accountId,
    Expression<Uint8List>? usernameCiphertext,
    Expression<Uint8List>? passwordCiphertext,
    Expression<String>? scheme,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (usernameCiphertext != null) 'username_ciphertext': usernameCiphertext,
      if (passwordCiphertext != null) 'password_ciphertext': passwordCiphertext,
      if (scheme != null) 'scheme': scheme,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CredentialAccountsCompanion copyWith({
    Value<String>? accountId,
    Value<Uint8List>? usernameCiphertext,
    Value<Uint8List?>? passwordCiphertext,
    Value<String>? scheme,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return CredentialAccountsCompanion(
      accountId: accountId ?? this.accountId,
      usernameCiphertext: usernameCiphertext ?? this.usernameCiphertext,
      passwordCiphertext: passwordCiphertext ?? this.passwordCiphertext,
      scheme: scheme ?? this.scheme,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (usernameCiphertext.present) {
      map['username_ciphertext'] = Variable<Uint8List>(
        usernameCiphertext.value,
      );
    }
    if (passwordCiphertext.present) {
      map['password_ciphertext'] = Variable<Uint8List>(
        passwordCiphertext.value,
      );
    }
    if (scheme.present) {
      map['scheme'] = Variable<String>(scheme.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CredentialAccountsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('usernameCiphertext: $usernameCiphertext, ')
          ..write('passwordCiphertext: $passwordCiphertext, ')
          ..write('scheme: $scheme, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SourceConfigsTable extends SourceConfigs
    with TableInfo<$SourceConfigsTable, SourceConfig> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SourceConfigsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _configJsonMeta = const VerificationMeta(
    'configJson',
  );
  @override
  late final GeneratedColumn<String> configJson = GeneratedColumn<String>(
    'config_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _lastSuccessAtMeta = const VerificationMeta(
    'lastSuccessAt',
  );
  @override
  late final GeneratedColumn<int> lastSuccessAt = GeneratedColumn<int>(
    'last_success_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _retryAfterMeta = const VerificationMeta(
    'retryAfter',
  );
  @override
  late final GeneratedColumn<int> retryAfter = GeneratedColumn<int>(
    'retry_after',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    source,
    enabled,
    configJson,
    lastSuccessAt,
    retryAfter,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'source_configs';
  @override
  VerificationContext validateIntegrity(
    Insertable<SourceConfig> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    if (data.containsKey('config_json')) {
      context.handle(
        _configJsonMeta,
        configJson.isAcceptableOrUnknown(data['config_json']!, _configJsonMeta),
      );
    }
    if (data.containsKey('last_success_at')) {
      context.handle(
        _lastSuccessAtMeta,
        lastSuccessAt.isAcceptableOrUnknown(
          data['last_success_at']!,
          _lastSuccessAtMeta,
        ),
      );
    }
    if (data.containsKey('retry_after')) {
      context.handle(
        _retryAfterMeta,
        retryAfter.isAcceptableOrUnknown(data['retry_after']!, _retryAfterMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, source},
  ];
  @override
  SourceConfig map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SourceConfig(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
      )!,
      configJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}config_json'],
      )!,
      lastSuccessAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_success_at'],
      ),
      retryAfter: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}retry_after'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $SourceConfigsTable createAlias(String alias) {
    return $SourceConfigsTable(attachedDatabase, alias);
  }
}

class SourceConfig extends DataClass implements Insertable<SourceConfig> {
  final String id;
  final String accountId;
  final String source;
  final bool enabled;
  final String configJson;
  final int? lastSuccessAt;
  final int? retryAfter;
  final int updatedAt;
  const SourceConfig({
    required this.id,
    required this.accountId,
    required this.source,
    required this.enabled,
    required this.configJson,
    this.lastSuccessAt,
    this.retryAfter,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['source'] = Variable<String>(source);
    map['enabled'] = Variable<bool>(enabled);
    map['config_json'] = Variable<String>(configJson);
    if (!nullToAbsent || lastSuccessAt != null) {
      map['last_success_at'] = Variable<int>(lastSuccessAt);
    }
    if (!nullToAbsent || retryAfter != null) {
      map['retry_after'] = Variable<int>(retryAfter);
    }
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  SourceConfigsCompanion toCompanion(bool nullToAbsent) {
    return SourceConfigsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      source: Value(source),
      enabled: Value(enabled),
      configJson: Value(configJson),
      lastSuccessAt: lastSuccessAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSuccessAt),
      retryAfter: retryAfter == null && nullToAbsent
          ? const Value.absent()
          : Value(retryAfter),
      updatedAt: Value(updatedAt),
    );
  }

  factory SourceConfig.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SourceConfig(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      source: serializer.fromJson<String>(json['source']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      configJson: serializer.fromJson<String>(json['configJson']),
      lastSuccessAt: serializer.fromJson<int?>(json['lastSuccessAt']),
      retryAfter: serializer.fromJson<int?>(json['retryAfter']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'source': serializer.toJson<String>(source),
      'enabled': serializer.toJson<bool>(enabled),
      'configJson': serializer.toJson<String>(configJson),
      'lastSuccessAt': serializer.toJson<int?>(lastSuccessAt),
      'retryAfter': serializer.toJson<int?>(retryAfter),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  SourceConfig copyWith({
    String? id,
    String? accountId,
    String? source,
    bool? enabled,
    String? configJson,
    Value<int?> lastSuccessAt = const Value.absent(),
    Value<int?> retryAfter = const Value.absent(),
    int? updatedAt,
  }) => SourceConfig(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    source: source ?? this.source,
    enabled: enabled ?? this.enabled,
    configJson: configJson ?? this.configJson,
    lastSuccessAt: lastSuccessAt.present
        ? lastSuccessAt.value
        : this.lastSuccessAt,
    retryAfter: retryAfter.present ? retryAfter.value : this.retryAfter,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  SourceConfig copyWithCompanion(SourceConfigsCompanion data) {
    return SourceConfig(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      source: data.source.present ? data.source.value : this.source,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      configJson: data.configJson.present
          ? data.configJson.value
          : this.configJson,
      lastSuccessAt: data.lastSuccessAt.present
          ? data.lastSuccessAt.value
          : this.lastSuccessAt,
      retryAfter: data.retryAfter.present
          ? data.retryAfter.value
          : this.retryAfter,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SourceConfig(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('enabled: $enabled, ')
          ..write('configJson: $configJson, ')
          ..write('lastSuccessAt: $lastSuccessAt, ')
          ..write('retryAfter: $retryAfter, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    source,
    enabled,
    configJson,
    lastSuccessAt,
    retryAfter,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SourceConfig &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.source == this.source &&
          other.enabled == this.enabled &&
          other.configJson == this.configJson &&
          other.lastSuccessAt == this.lastSuccessAt &&
          other.retryAfter == this.retryAfter &&
          other.updatedAt == this.updatedAt);
}

class SourceConfigsCompanion extends UpdateCompanion<SourceConfig> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> source;
  final Value<bool> enabled;
  final Value<String> configJson;
  final Value<int?> lastSuccessAt;
  final Value<int?> retryAfter;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const SourceConfigsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.source = const Value.absent(),
    this.enabled = const Value.absent(),
    this.configJson = const Value.absent(),
    this.lastSuccessAt = const Value.absent(),
    this.retryAfter = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SourceConfigsCompanion.insert({
    required String id,
    required String accountId,
    required String source,
    this.enabled = const Value.absent(),
    this.configJson = const Value.absent(),
    this.lastSuccessAt = const Value.absent(),
    this.retryAfter = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       source = Value(source),
       updatedAt = Value(updatedAt);
  static Insertable<SourceConfig> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? source,
    Expression<bool>? enabled,
    Expression<String>? configJson,
    Expression<int>? lastSuccessAt,
    Expression<int>? retryAfter,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (source != null) 'source': source,
      if (enabled != null) 'enabled': enabled,
      if (configJson != null) 'config_json': configJson,
      if (lastSuccessAt != null) 'last_success_at': lastSuccessAt,
      if (retryAfter != null) 'retry_after': retryAfter,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SourceConfigsCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? source,
    Value<bool>? enabled,
    Value<String>? configJson,
    Value<int?>? lastSuccessAt,
    Value<int?>? retryAfter,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return SourceConfigsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      source: source ?? this.source,
      enabled: enabled ?? this.enabled,
      configJson: configJson ?? this.configJson,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      retryAfter: retryAfter ?? this.retryAfter,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (configJson.present) {
      map['config_json'] = Variable<String>(configJson.value);
    }
    if (lastSuccessAt.present) {
      map['last_success_at'] = Variable<int>(lastSuccessAt.value);
    }
    if (retryAfter.present) {
      map['retry_after'] = Variable<int>(retryAfter.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SourceConfigsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('enabled: $enabled, ')
          ..write('configJson: $configJson, ')
          ..write('lastSuccessAt: $lastSuccessAt, ')
          ..write('retryAfter: $retryAfter, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ImportBatchesTable extends ImportBatches
    with TableInfo<$ImportBatchesTable, ImportBatche> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ImportBatchesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _bundleIdMeta = const VerificationMeta(
    'bundleId',
  );
  @override
  late final GeneratedColumn<String> bundleId = GeneratedColumn<String>(
    'bundle_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _digestMeta = const VerificationMeta('digest');
  @override
  late final GeneratedColumn<String> digest = GeneratedColumn<String>(
    'digest',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeKeyMeta = const VerificationMeta(
    'scopeKey',
  );
  @override
  late final GeneratedColumn<String> scopeKey = GeneratedColumn<String>(
    'scope_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _importedAtMeta = const VerificationMeta(
    'importedAt',
  );
  @override
  late final GeneratedColumn<int> importedAt = GeneratedColumn<int>(
    'imported_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originMeta = const VerificationMeta('origin');
  @override
  late final GeneratedColumn<String> origin = GeneratedColumn<String>(
    'origin',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    bundleId,
    digest,
    source,
    scopeKey,
    importedAt,
    origin,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'import_batches';
  @override
  VerificationContext validateIntegrity(
    Insertable<ImportBatche> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('bundle_id')) {
      context.handle(
        _bundleIdMeta,
        bundleId.isAcceptableOrUnknown(data['bundle_id']!, _bundleIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bundleIdMeta);
    }
    if (data.containsKey('digest')) {
      context.handle(
        _digestMeta,
        digest.isAcceptableOrUnknown(data['digest']!, _digestMeta),
      );
    } else if (isInserting) {
      context.missing(_digestMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('scope_key')) {
      context.handle(
        _scopeKeyMeta,
        scopeKey.isAcceptableOrUnknown(data['scope_key']!, _scopeKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeKeyMeta);
    }
    if (data.containsKey('imported_at')) {
      context.handle(
        _importedAtMeta,
        importedAt.isAcceptableOrUnknown(data['imported_at']!, _importedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_importedAtMeta);
    }
    if (data.containsKey('origin')) {
      context.handle(
        _originMeta,
        origin.isAcceptableOrUnknown(data['origin']!, _originMeta),
      );
    } else if (isInserting) {
      context.missing(_originMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, bundleId},
    {accountId, digest},
  ];
  @override
  ImportBatche map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ImportBatche(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      bundleId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bundle_id'],
      )!,
      digest: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}digest'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      scopeKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_key'],
      )!,
      importedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}imported_at'],
      )!,
      origin: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin'],
      )!,
    );
  }

  @override
  $ImportBatchesTable createAlias(String alias) {
    return $ImportBatchesTable(attachedDatabase, alias);
  }
}

class ImportBatche extends DataClass implements Insertable<ImportBatche> {
  final String id;
  final String accountId;
  final String bundleId;
  final String digest;
  final String source;
  final String scopeKey;
  final int importedAt;
  final String origin;
  const ImportBatche({
    required this.id,
    required this.accountId,
    required this.bundleId,
    required this.digest,
    required this.source,
    required this.scopeKey,
    required this.importedAt,
    required this.origin,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['bundle_id'] = Variable<String>(bundleId);
    map['digest'] = Variable<String>(digest);
    map['source'] = Variable<String>(source);
    map['scope_key'] = Variable<String>(scopeKey);
    map['imported_at'] = Variable<int>(importedAt);
    map['origin'] = Variable<String>(origin);
    return map;
  }

  ImportBatchesCompanion toCompanion(bool nullToAbsent) {
    return ImportBatchesCompanion(
      id: Value(id),
      accountId: Value(accountId),
      bundleId: Value(bundleId),
      digest: Value(digest),
      source: Value(source),
      scopeKey: Value(scopeKey),
      importedAt: Value(importedAt),
      origin: Value(origin),
    );
  }

  factory ImportBatche.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ImportBatche(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      bundleId: serializer.fromJson<String>(json['bundleId']),
      digest: serializer.fromJson<String>(json['digest']),
      source: serializer.fromJson<String>(json['source']),
      scopeKey: serializer.fromJson<String>(json['scopeKey']),
      importedAt: serializer.fromJson<int>(json['importedAt']),
      origin: serializer.fromJson<String>(json['origin']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'bundleId': serializer.toJson<String>(bundleId),
      'digest': serializer.toJson<String>(digest),
      'source': serializer.toJson<String>(source),
      'scopeKey': serializer.toJson<String>(scopeKey),
      'importedAt': serializer.toJson<int>(importedAt),
      'origin': serializer.toJson<String>(origin),
    };
  }

  ImportBatche copyWith({
    String? id,
    String? accountId,
    String? bundleId,
    String? digest,
    String? source,
    String? scopeKey,
    int? importedAt,
    String? origin,
  }) => ImportBatche(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    bundleId: bundleId ?? this.bundleId,
    digest: digest ?? this.digest,
    source: source ?? this.source,
    scopeKey: scopeKey ?? this.scopeKey,
    importedAt: importedAt ?? this.importedAt,
    origin: origin ?? this.origin,
  );
  ImportBatche copyWithCompanion(ImportBatchesCompanion data) {
    return ImportBatche(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      bundleId: data.bundleId.present ? data.bundleId.value : this.bundleId,
      digest: data.digest.present ? data.digest.value : this.digest,
      source: data.source.present ? data.source.value : this.source,
      scopeKey: data.scopeKey.present ? data.scopeKey.value : this.scopeKey,
      importedAt: data.importedAt.present
          ? data.importedAt.value
          : this.importedAt,
      origin: data.origin.present ? data.origin.value : this.origin,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ImportBatche(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('bundleId: $bundleId, ')
          ..write('digest: $digest, ')
          ..write('source: $source, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('importedAt: $importedAt, ')
          ..write('origin: $origin')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    bundleId,
    digest,
    source,
    scopeKey,
    importedAt,
    origin,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ImportBatche &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.bundleId == this.bundleId &&
          other.digest == this.digest &&
          other.source == this.source &&
          other.scopeKey == this.scopeKey &&
          other.importedAt == this.importedAt &&
          other.origin == this.origin);
}

class ImportBatchesCompanion extends UpdateCompanion<ImportBatche> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> bundleId;
  final Value<String> digest;
  final Value<String> source;
  final Value<String> scopeKey;
  final Value<int> importedAt;
  final Value<String> origin;
  final Value<int> rowid;
  const ImportBatchesCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.bundleId = const Value.absent(),
    this.digest = const Value.absent(),
    this.source = const Value.absent(),
    this.scopeKey = const Value.absent(),
    this.importedAt = const Value.absent(),
    this.origin = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ImportBatchesCompanion.insert({
    required String id,
    required String accountId,
    required String bundleId,
    required String digest,
    required String source,
    required String scopeKey,
    required int importedAt,
    required String origin,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       bundleId = Value(bundleId),
       digest = Value(digest),
       source = Value(source),
       scopeKey = Value(scopeKey),
       importedAt = Value(importedAt),
       origin = Value(origin);
  static Insertable<ImportBatche> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? bundleId,
    Expression<String>? digest,
    Expression<String>? source,
    Expression<String>? scopeKey,
    Expression<int>? importedAt,
    Expression<String>? origin,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (bundleId != null) 'bundle_id': bundleId,
      if (digest != null) 'digest': digest,
      if (source != null) 'source': source,
      if (scopeKey != null) 'scope_key': scopeKey,
      if (importedAt != null) 'imported_at': importedAt,
      if (origin != null) 'origin': origin,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ImportBatchesCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? bundleId,
    Value<String>? digest,
    Value<String>? source,
    Value<String>? scopeKey,
    Value<int>? importedAt,
    Value<String>? origin,
    Value<int>? rowid,
  }) {
    return ImportBatchesCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      bundleId: bundleId ?? this.bundleId,
      digest: digest ?? this.digest,
      source: source ?? this.source,
      scopeKey: scopeKey ?? this.scopeKey,
      importedAt: importedAt ?? this.importedAt,
      origin: origin ?? this.origin,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (bundleId.present) {
      map['bundle_id'] = Variable<String>(bundleId.value);
    }
    if (digest.present) {
      map['digest'] = Variable<String>(digest.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (scopeKey.present) {
      map['scope_key'] = Variable<String>(scopeKey.value);
    }
    if (importedAt.present) {
      map['imported_at'] = Variable<int>(importedAt.value);
    }
    if (origin.present) {
      map['origin'] = Variable<String>(origin.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ImportBatchesCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('bundleId: $bundleId, ')
          ..write('digest: $digest, ')
          ..write('source: $source, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('importedAt: $importedAt, ')
          ..write('origin: $origin, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SourceRecordsTable extends SourceRecords
    with TableInfo<$SourceRecordsTable, SourceRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SourceRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityTypeMeta = const VerificationMeta(
    'entityType',
  );
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
    'entity_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _externalIdMeta = const VerificationMeta(
    'externalId',
  );
  @override
  late final GeneratedColumn<String> externalId = GeneratedColumn<String>(
    'external_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localEntityIdMeta = const VerificationMeta(
    'localEntityId',
  );
  @override
  late final GeneratedColumn<String> localEntityId = GeneratedColumn<String>(
    'local_entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceStatusMeta = const VerificationMeta(
    'sourceStatus',
  );
  @override
  late final GeneratedColumn<String> sourceStatus = GeneratedColumn<String>(
    'source_status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _presenceMeta = const VerificationMeta(
    'presence',
  );
  @override
  late final GeneratedColumn<String> presence = GeneratedColumn<String>(
    'presence',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeKeyMeta = const VerificationMeta(
    'scopeKey',
  );
  @override
  late final GeneratedColumn<String> scopeKey = GeneratedColumn<String>(
    'scope_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _importBatchIdMeta = const VerificationMeta(
    'importBatchId',
  );
  @override
  late final GeneratedColumn<String> importBatchId = GeneratedColumn<String>(
    'import_batch_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES import_batches (id) ON DELETE RESTRICT',
    ),
  );
  static const VerificationMeta _sourceUpdatedAtMeta = const VerificationMeta(
    'sourceUpdatedAt',
  );
  @override
  late final GeneratedColumn<int> sourceUpdatedAt = GeneratedColumn<int>(
    'source_updated_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _firstObservedAtMeta = const VerificationMeta(
    'firstObservedAt',
  );
  @override
  late final GeneratedColumn<int> firstObservedAt = GeneratedColumn<int>(
    'first_observed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastObservedAtMeta = const VerificationMeta(
    'lastObservedAt',
  );
  @override
  late final GeneratedColumn<int> lastObservedAt = GeneratedColumn<int>(
    'last_observed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    source,
    entityType,
    externalId,
    localEntityId,
    sourceStatus,
    presence,
    scopeKey,
    importBatchId,
    sourceUpdatedAt,
    firstObservedAt,
    lastObservedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'source_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<SourceRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('entity_type')) {
      context.handle(
        _entityTypeMeta,
        entityType.isAcceptableOrUnknown(data['entity_type']!, _entityTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('external_id')) {
      context.handle(
        _externalIdMeta,
        externalId.isAcceptableOrUnknown(data['external_id']!, _externalIdMeta),
      );
    } else if (isInserting) {
      context.missing(_externalIdMeta);
    }
    if (data.containsKey('local_entity_id')) {
      context.handle(
        _localEntityIdMeta,
        localEntityId.isAcceptableOrUnknown(
          data['local_entity_id']!,
          _localEntityIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localEntityIdMeta);
    }
    if (data.containsKey('source_status')) {
      context.handle(
        _sourceStatusMeta,
        sourceStatus.isAcceptableOrUnknown(
          data['source_status']!,
          _sourceStatusMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceStatusMeta);
    }
    if (data.containsKey('presence')) {
      context.handle(
        _presenceMeta,
        presence.isAcceptableOrUnknown(data['presence']!, _presenceMeta),
      );
    } else if (isInserting) {
      context.missing(_presenceMeta);
    }
    if (data.containsKey('scope_key')) {
      context.handle(
        _scopeKeyMeta,
        scopeKey.isAcceptableOrUnknown(data['scope_key']!, _scopeKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeKeyMeta);
    }
    if (data.containsKey('import_batch_id')) {
      context.handle(
        _importBatchIdMeta,
        importBatchId.isAcceptableOrUnknown(
          data['import_batch_id']!,
          _importBatchIdMeta,
        ),
      );
    }
    if (data.containsKey('source_updated_at')) {
      context.handle(
        _sourceUpdatedAtMeta,
        sourceUpdatedAt.isAcceptableOrUnknown(
          data['source_updated_at']!,
          _sourceUpdatedAtMeta,
        ),
      );
    }
    if (data.containsKey('first_observed_at')) {
      context.handle(
        _firstObservedAtMeta,
        firstObservedAt.isAcceptableOrUnknown(
          data['first_observed_at']!,
          _firstObservedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_firstObservedAtMeta);
    }
    if (data.containsKey('last_observed_at')) {
      context.handle(
        _lastObservedAtMeta,
        lastObservedAt.isAcceptableOrUnknown(
          data['last_observed_at']!,
          _lastObservedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastObservedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, source, entityType, externalId},
  ];
  @override
  SourceRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SourceRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      entityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_type'],
      )!,
      externalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}external_id'],
      )!,
      localEntityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_entity_id'],
      )!,
      sourceStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_status'],
      )!,
      presence: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}presence'],
      )!,
      scopeKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_key'],
      )!,
      importBatchId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}import_batch_id'],
      ),
      sourceUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}source_updated_at'],
      ),
      firstObservedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}first_observed_at'],
      )!,
      lastObservedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_observed_at'],
      )!,
    );
  }

  @override
  $SourceRecordsTable createAlias(String alias) {
    return $SourceRecordsTable(attachedDatabase, alias);
  }
}

class SourceRecord extends DataClass implements Insertable<SourceRecord> {
  final String id;
  final String accountId;
  final String source;
  final String entityType;
  final String externalId;
  final String localEntityId;
  final String sourceStatus;
  final String presence;
  final String scopeKey;
  final String? importBatchId;
  final int? sourceUpdatedAt;
  final int firstObservedAt;
  final int lastObservedAt;
  const SourceRecord({
    required this.id,
    required this.accountId,
    required this.source,
    required this.entityType,
    required this.externalId,
    required this.localEntityId,
    required this.sourceStatus,
    required this.presence,
    required this.scopeKey,
    this.importBatchId,
    this.sourceUpdatedAt,
    required this.firstObservedAt,
    required this.lastObservedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['source'] = Variable<String>(source);
    map['entity_type'] = Variable<String>(entityType);
    map['external_id'] = Variable<String>(externalId);
    map['local_entity_id'] = Variable<String>(localEntityId);
    map['source_status'] = Variable<String>(sourceStatus);
    map['presence'] = Variable<String>(presence);
    map['scope_key'] = Variable<String>(scopeKey);
    if (!nullToAbsent || importBatchId != null) {
      map['import_batch_id'] = Variable<String>(importBatchId);
    }
    if (!nullToAbsent || sourceUpdatedAt != null) {
      map['source_updated_at'] = Variable<int>(sourceUpdatedAt);
    }
    map['first_observed_at'] = Variable<int>(firstObservedAt);
    map['last_observed_at'] = Variable<int>(lastObservedAt);
    return map;
  }

  SourceRecordsCompanion toCompanion(bool nullToAbsent) {
    return SourceRecordsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      source: Value(source),
      entityType: Value(entityType),
      externalId: Value(externalId),
      localEntityId: Value(localEntityId),
      sourceStatus: Value(sourceStatus),
      presence: Value(presence),
      scopeKey: Value(scopeKey),
      importBatchId: importBatchId == null && nullToAbsent
          ? const Value.absent()
          : Value(importBatchId),
      sourceUpdatedAt: sourceUpdatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceUpdatedAt),
      firstObservedAt: Value(firstObservedAt),
      lastObservedAt: Value(lastObservedAt),
    );
  }

  factory SourceRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SourceRecord(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      source: serializer.fromJson<String>(json['source']),
      entityType: serializer.fromJson<String>(json['entityType']),
      externalId: serializer.fromJson<String>(json['externalId']),
      localEntityId: serializer.fromJson<String>(json['localEntityId']),
      sourceStatus: serializer.fromJson<String>(json['sourceStatus']),
      presence: serializer.fromJson<String>(json['presence']),
      scopeKey: serializer.fromJson<String>(json['scopeKey']),
      importBatchId: serializer.fromJson<String?>(json['importBatchId']),
      sourceUpdatedAt: serializer.fromJson<int?>(json['sourceUpdatedAt']),
      firstObservedAt: serializer.fromJson<int>(json['firstObservedAt']),
      lastObservedAt: serializer.fromJson<int>(json['lastObservedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'source': serializer.toJson<String>(source),
      'entityType': serializer.toJson<String>(entityType),
      'externalId': serializer.toJson<String>(externalId),
      'localEntityId': serializer.toJson<String>(localEntityId),
      'sourceStatus': serializer.toJson<String>(sourceStatus),
      'presence': serializer.toJson<String>(presence),
      'scopeKey': serializer.toJson<String>(scopeKey),
      'importBatchId': serializer.toJson<String?>(importBatchId),
      'sourceUpdatedAt': serializer.toJson<int?>(sourceUpdatedAt),
      'firstObservedAt': serializer.toJson<int>(firstObservedAt),
      'lastObservedAt': serializer.toJson<int>(lastObservedAt),
    };
  }

  SourceRecord copyWith({
    String? id,
    String? accountId,
    String? source,
    String? entityType,
    String? externalId,
    String? localEntityId,
    String? sourceStatus,
    String? presence,
    String? scopeKey,
    Value<String?> importBatchId = const Value.absent(),
    Value<int?> sourceUpdatedAt = const Value.absent(),
    int? firstObservedAt,
    int? lastObservedAt,
  }) => SourceRecord(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    source: source ?? this.source,
    entityType: entityType ?? this.entityType,
    externalId: externalId ?? this.externalId,
    localEntityId: localEntityId ?? this.localEntityId,
    sourceStatus: sourceStatus ?? this.sourceStatus,
    presence: presence ?? this.presence,
    scopeKey: scopeKey ?? this.scopeKey,
    importBatchId: importBatchId.present
        ? importBatchId.value
        : this.importBatchId,
    sourceUpdatedAt: sourceUpdatedAt.present
        ? sourceUpdatedAt.value
        : this.sourceUpdatedAt,
    firstObservedAt: firstObservedAt ?? this.firstObservedAt,
    lastObservedAt: lastObservedAt ?? this.lastObservedAt,
  );
  SourceRecord copyWithCompanion(SourceRecordsCompanion data) {
    return SourceRecord(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      source: data.source.present ? data.source.value : this.source,
      entityType: data.entityType.present
          ? data.entityType.value
          : this.entityType,
      externalId: data.externalId.present
          ? data.externalId.value
          : this.externalId,
      localEntityId: data.localEntityId.present
          ? data.localEntityId.value
          : this.localEntityId,
      sourceStatus: data.sourceStatus.present
          ? data.sourceStatus.value
          : this.sourceStatus,
      presence: data.presence.present ? data.presence.value : this.presence,
      scopeKey: data.scopeKey.present ? data.scopeKey.value : this.scopeKey,
      importBatchId: data.importBatchId.present
          ? data.importBatchId.value
          : this.importBatchId,
      sourceUpdatedAt: data.sourceUpdatedAt.present
          ? data.sourceUpdatedAt.value
          : this.sourceUpdatedAt,
      firstObservedAt: data.firstObservedAt.present
          ? data.firstObservedAt.value
          : this.firstObservedAt,
      lastObservedAt: data.lastObservedAt.present
          ? data.lastObservedAt.value
          : this.lastObservedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SourceRecord(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('entityType: $entityType, ')
          ..write('externalId: $externalId, ')
          ..write('localEntityId: $localEntityId, ')
          ..write('sourceStatus: $sourceStatus, ')
          ..write('presence: $presence, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('importBatchId: $importBatchId, ')
          ..write('sourceUpdatedAt: $sourceUpdatedAt, ')
          ..write('firstObservedAt: $firstObservedAt, ')
          ..write('lastObservedAt: $lastObservedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    source,
    entityType,
    externalId,
    localEntityId,
    sourceStatus,
    presence,
    scopeKey,
    importBatchId,
    sourceUpdatedAt,
    firstObservedAt,
    lastObservedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SourceRecord &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.source == this.source &&
          other.entityType == this.entityType &&
          other.externalId == this.externalId &&
          other.localEntityId == this.localEntityId &&
          other.sourceStatus == this.sourceStatus &&
          other.presence == this.presence &&
          other.scopeKey == this.scopeKey &&
          other.importBatchId == this.importBatchId &&
          other.sourceUpdatedAt == this.sourceUpdatedAt &&
          other.firstObservedAt == this.firstObservedAt &&
          other.lastObservedAt == this.lastObservedAt);
}

class SourceRecordsCompanion extends UpdateCompanion<SourceRecord> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> source;
  final Value<String> entityType;
  final Value<String> externalId;
  final Value<String> localEntityId;
  final Value<String> sourceStatus;
  final Value<String> presence;
  final Value<String> scopeKey;
  final Value<String?> importBatchId;
  final Value<int?> sourceUpdatedAt;
  final Value<int> firstObservedAt;
  final Value<int> lastObservedAt;
  final Value<int> rowid;
  const SourceRecordsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.source = const Value.absent(),
    this.entityType = const Value.absent(),
    this.externalId = const Value.absent(),
    this.localEntityId = const Value.absent(),
    this.sourceStatus = const Value.absent(),
    this.presence = const Value.absent(),
    this.scopeKey = const Value.absent(),
    this.importBatchId = const Value.absent(),
    this.sourceUpdatedAt = const Value.absent(),
    this.firstObservedAt = const Value.absent(),
    this.lastObservedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SourceRecordsCompanion.insert({
    required String id,
    required String accountId,
    required String source,
    required String entityType,
    required String externalId,
    required String localEntityId,
    required String sourceStatus,
    required String presence,
    required String scopeKey,
    this.importBatchId = const Value.absent(),
    this.sourceUpdatedAt = const Value.absent(),
    required int firstObservedAt,
    required int lastObservedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       source = Value(source),
       entityType = Value(entityType),
       externalId = Value(externalId),
       localEntityId = Value(localEntityId),
       sourceStatus = Value(sourceStatus),
       presence = Value(presence),
       scopeKey = Value(scopeKey),
       firstObservedAt = Value(firstObservedAt),
       lastObservedAt = Value(lastObservedAt);
  static Insertable<SourceRecord> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? source,
    Expression<String>? entityType,
    Expression<String>? externalId,
    Expression<String>? localEntityId,
    Expression<String>? sourceStatus,
    Expression<String>? presence,
    Expression<String>? scopeKey,
    Expression<String>? importBatchId,
    Expression<int>? sourceUpdatedAt,
    Expression<int>? firstObservedAt,
    Expression<int>? lastObservedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (source != null) 'source': source,
      if (entityType != null) 'entity_type': entityType,
      if (externalId != null) 'external_id': externalId,
      if (localEntityId != null) 'local_entity_id': localEntityId,
      if (sourceStatus != null) 'source_status': sourceStatus,
      if (presence != null) 'presence': presence,
      if (scopeKey != null) 'scope_key': scopeKey,
      if (importBatchId != null) 'import_batch_id': importBatchId,
      if (sourceUpdatedAt != null) 'source_updated_at': sourceUpdatedAt,
      if (firstObservedAt != null) 'first_observed_at': firstObservedAt,
      if (lastObservedAt != null) 'last_observed_at': lastObservedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SourceRecordsCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? source,
    Value<String>? entityType,
    Value<String>? externalId,
    Value<String>? localEntityId,
    Value<String>? sourceStatus,
    Value<String>? presence,
    Value<String>? scopeKey,
    Value<String?>? importBatchId,
    Value<int?>? sourceUpdatedAt,
    Value<int>? firstObservedAt,
    Value<int>? lastObservedAt,
    Value<int>? rowid,
  }) {
    return SourceRecordsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      source: source ?? this.source,
      entityType: entityType ?? this.entityType,
      externalId: externalId ?? this.externalId,
      localEntityId: localEntityId ?? this.localEntityId,
      sourceStatus: sourceStatus ?? this.sourceStatus,
      presence: presence ?? this.presence,
      scopeKey: scopeKey ?? this.scopeKey,
      importBatchId: importBatchId ?? this.importBatchId,
      sourceUpdatedAt: sourceUpdatedAt ?? this.sourceUpdatedAt,
      firstObservedAt: firstObservedAt ?? this.firstObservedAt,
      lastObservedAt: lastObservedAt ?? this.lastObservedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (externalId.present) {
      map['external_id'] = Variable<String>(externalId.value);
    }
    if (localEntityId.present) {
      map['local_entity_id'] = Variable<String>(localEntityId.value);
    }
    if (sourceStatus.present) {
      map['source_status'] = Variable<String>(sourceStatus.value);
    }
    if (presence.present) {
      map['presence'] = Variable<String>(presence.value);
    }
    if (scopeKey.present) {
      map['scope_key'] = Variable<String>(scopeKey.value);
    }
    if (importBatchId.present) {
      map['import_batch_id'] = Variable<String>(importBatchId.value);
    }
    if (sourceUpdatedAt.present) {
      map['source_updated_at'] = Variable<int>(sourceUpdatedAt.value);
    }
    if (firstObservedAt.present) {
      map['first_observed_at'] = Variable<int>(firstObservedAt.value);
    }
    if (lastObservedAt.present) {
      map['last_observed_at'] = Variable<int>(lastObservedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SourceRecordsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('entityType: $entityType, ')
          ..write('externalId: $externalId, ')
          ..write('localEntityId: $localEntityId, ')
          ..write('sourceStatus: $sourceStatus, ')
          ..write('presence: $presence, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('importBatchId: $importBatchId, ')
          ..write('sourceUpdatedAt: $sourceUpdatedAt, ')
          ..write('firstObservedAt: $firstObservedAt, ')
          ..write('lastObservedAt: $lastObservedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncRunsTable extends SyncRuns with TableInfo<$SyncRunsTable, SyncRun> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncRunsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _triggerMeta = const VerificationMeta(
    'trigger',
  );
  @override
  late final GeneratedColumn<String> trigger = GeneratedColumn<String>(
    'trigger',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resultCodeMeta = const VerificationMeta(
    'resultCode',
  );
  @override
  late final GeneratedColumn<String> resultCode = GeneratedColumn<String>(
    'result_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<int> startedAt = GeneratedColumn<int>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _finishedAtMeta = const VerificationMeta(
    'finishedAt',
  );
  @override
  late final GeneratedColumn<int> finishedAt = GeneratedColumn<int>(
    'finished_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _importBatchIdMeta = const VerificationMeta(
    'importBatchId',
  );
  @override
  late final GeneratedColumn<String> importBatchId = GeneratedColumn<String>(
    'import_batch_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES import_batches (id) ON DELETE SET NULL',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    source,
    trigger,
    state,
    resultCode,
    startedAt,
    finishedAt,
    importBatchId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_runs';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncRun> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('trigger')) {
      context.handle(
        _triggerMeta,
        trigger.isAcceptableOrUnknown(data['trigger']!, _triggerMeta),
      );
    } else if (isInserting) {
      context.missing(_triggerMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('result_code')) {
      context.handle(
        _resultCodeMeta,
        resultCode.isAcceptableOrUnknown(data['result_code']!, _resultCodeMeta),
      );
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('finished_at')) {
      context.handle(
        _finishedAtMeta,
        finishedAt.isAcceptableOrUnknown(data['finished_at']!, _finishedAtMeta),
      );
    }
    if (data.containsKey('import_batch_id')) {
      context.handle(
        _importBatchIdMeta,
        importBatchId.isAcceptableOrUnknown(
          data['import_batch_id']!,
          _importBatchIdMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncRun map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncRun(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      trigger: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}trigger'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      resultCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}result_code'],
      ),
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}started_at'],
      )!,
      finishedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}finished_at'],
      ),
      importBatchId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}import_batch_id'],
      ),
    );
  }

  @override
  $SyncRunsTable createAlias(String alias) {
    return $SyncRunsTable(attachedDatabase, alias);
  }
}

class SyncRun extends DataClass implements Insertable<SyncRun> {
  final String id;
  final String accountId;
  final String source;
  final String trigger;
  final String state;
  final String? resultCode;
  final int startedAt;
  final int? finishedAt;
  final String? importBatchId;
  const SyncRun({
    required this.id,
    required this.accountId,
    required this.source,
    required this.trigger,
    required this.state,
    this.resultCode,
    required this.startedAt,
    this.finishedAt,
    this.importBatchId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['source'] = Variable<String>(source);
    map['trigger'] = Variable<String>(trigger);
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || resultCode != null) {
      map['result_code'] = Variable<String>(resultCode);
    }
    map['started_at'] = Variable<int>(startedAt);
    if (!nullToAbsent || finishedAt != null) {
      map['finished_at'] = Variable<int>(finishedAt);
    }
    if (!nullToAbsent || importBatchId != null) {
      map['import_batch_id'] = Variable<String>(importBatchId);
    }
    return map;
  }

  SyncRunsCompanion toCompanion(bool nullToAbsent) {
    return SyncRunsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      source: Value(source),
      trigger: Value(trigger),
      state: Value(state),
      resultCode: resultCode == null && nullToAbsent
          ? const Value.absent()
          : Value(resultCode),
      startedAt: Value(startedAt),
      finishedAt: finishedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(finishedAt),
      importBatchId: importBatchId == null && nullToAbsent
          ? const Value.absent()
          : Value(importBatchId),
    );
  }

  factory SyncRun.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncRun(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      source: serializer.fromJson<String>(json['source']),
      trigger: serializer.fromJson<String>(json['trigger']),
      state: serializer.fromJson<String>(json['state']),
      resultCode: serializer.fromJson<String?>(json['resultCode']),
      startedAt: serializer.fromJson<int>(json['startedAt']),
      finishedAt: serializer.fromJson<int?>(json['finishedAt']),
      importBatchId: serializer.fromJson<String?>(json['importBatchId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'source': serializer.toJson<String>(source),
      'trigger': serializer.toJson<String>(trigger),
      'state': serializer.toJson<String>(state),
      'resultCode': serializer.toJson<String?>(resultCode),
      'startedAt': serializer.toJson<int>(startedAt),
      'finishedAt': serializer.toJson<int?>(finishedAt),
      'importBatchId': serializer.toJson<String?>(importBatchId),
    };
  }

  SyncRun copyWith({
    String? id,
    String? accountId,
    String? source,
    String? trigger,
    String? state,
    Value<String?> resultCode = const Value.absent(),
    int? startedAt,
    Value<int?> finishedAt = const Value.absent(),
    Value<String?> importBatchId = const Value.absent(),
  }) => SyncRun(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    source: source ?? this.source,
    trigger: trigger ?? this.trigger,
    state: state ?? this.state,
    resultCode: resultCode.present ? resultCode.value : this.resultCode,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt.present ? finishedAt.value : this.finishedAt,
    importBatchId: importBatchId.present
        ? importBatchId.value
        : this.importBatchId,
  );
  SyncRun copyWithCompanion(SyncRunsCompanion data) {
    return SyncRun(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      source: data.source.present ? data.source.value : this.source,
      trigger: data.trigger.present ? data.trigger.value : this.trigger,
      state: data.state.present ? data.state.value : this.state,
      resultCode: data.resultCode.present
          ? data.resultCode.value
          : this.resultCode,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      finishedAt: data.finishedAt.present
          ? data.finishedAt.value
          : this.finishedAt,
      importBatchId: data.importBatchId.present
          ? data.importBatchId.value
          : this.importBatchId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncRun(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('trigger: $trigger, ')
          ..write('state: $state, ')
          ..write('resultCode: $resultCode, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('importBatchId: $importBatchId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    source,
    trigger,
    state,
    resultCode,
    startedAt,
    finishedAt,
    importBatchId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncRun &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.source == this.source &&
          other.trigger == this.trigger &&
          other.state == this.state &&
          other.resultCode == this.resultCode &&
          other.startedAt == this.startedAt &&
          other.finishedAt == this.finishedAt &&
          other.importBatchId == this.importBatchId);
}

class SyncRunsCompanion extends UpdateCompanion<SyncRun> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> source;
  final Value<String> trigger;
  final Value<String> state;
  final Value<String?> resultCode;
  final Value<int> startedAt;
  final Value<int?> finishedAt;
  final Value<String?> importBatchId;
  final Value<int> rowid;
  const SyncRunsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.source = const Value.absent(),
    this.trigger = const Value.absent(),
    this.state = const Value.absent(),
    this.resultCode = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
    this.importBatchId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncRunsCompanion.insert({
    required String id,
    required String accountId,
    required String source,
    required String trigger,
    required String state,
    this.resultCode = const Value.absent(),
    required int startedAt,
    this.finishedAt = const Value.absent(),
    this.importBatchId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       source = Value(source),
       trigger = Value(trigger),
       state = Value(state),
       startedAt = Value(startedAt);
  static Insertable<SyncRun> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? source,
    Expression<String>? trigger,
    Expression<String>? state,
    Expression<String>? resultCode,
    Expression<int>? startedAt,
    Expression<int>? finishedAt,
    Expression<String>? importBatchId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (source != null) 'source': source,
      if (trigger != null) 'trigger': trigger,
      if (state != null) 'state': state,
      if (resultCode != null) 'result_code': resultCode,
      if (startedAt != null) 'started_at': startedAt,
      if (finishedAt != null) 'finished_at': finishedAt,
      if (importBatchId != null) 'import_batch_id': importBatchId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncRunsCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? source,
    Value<String>? trigger,
    Value<String>? state,
    Value<String?>? resultCode,
    Value<int>? startedAt,
    Value<int?>? finishedAt,
    Value<String?>? importBatchId,
    Value<int>? rowid,
  }) {
    return SyncRunsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      source: source ?? this.source,
      trigger: trigger ?? this.trigger,
      state: state ?? this.state,
      resultCode: resultCode ?? this.resultCode,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      importBatchId: importBatchId ?? this.importBatchId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (trigger.present) {
      map['trigger'] = Variable<String>(trigger.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (resultCode.present) {
      map['result_code'] = Variable<String>(resultCode.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<int>(startedAt.value);
    }
    if (finishedAt.present) {
      map['finished_at'] = Variable<int>(finishedAt.value);
    }
    if (importBatchId.present) {
      map['import_batch_id'] = Variable<String>(importBatchId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncRunsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('trigger: $trigger, ')
          ..write('state: $state, ')
          ..write('resultCode: $resultCode, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('importBatchId: $importBatchId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ActionLogsTable extends ActionLogs
    with TableInfo<$ActionLogsTable, ActionLog> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ActionLogsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_accounts (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actionTypeMeta = const VerificationMeta(
    'actionType',
  );
  @override
  late final GeneratedColumn<String> actionType = GeneratedColumn<String>(
    'action_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resultMeta = const VerificationMeta('result');
  @override
  late final GeneratedColumn<String> result = GeneratedColumn<String>(
    'result',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _safeSummaryMeta = const VerificationMeta(
    'safeSummary',
  );
  @override
  late final GeneratedColumn<String> safeSummary = GeneratedColumn<String>(
    'safe_summary',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _occurredAtMeta = const VerificationMeta(
    'occurredAt',
  );
  @override
  late final GeneratedColumn<int> occurredAt = GeneratedColumn<int>(
    'occurred_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    source,
    actionType,
    result,
    safeSummary,
    occurredAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'action_logs';
  @override
  VerificationContext validateIntegrity(
    Insertable<ActionLog> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('action_type')) {
      context.handle(
        _actionTypeMeta,
        actionType.isAcceptableOrUnknown(data['action_type']!, _actionTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_actionTypeMeta);
    }
    if (data.containsKey('result')) {
      context.handle(
        _resultMeta,
        result.isAcceptableOrUnknown(data['result']!, _resultMeta),
      );
    } else if (isInserting) {
      context.missing(_resultMeta);
    }
    if (data.containsKey('safe_summary')) {
      context.handle(
        _safeSummaryMeta,
        safeSummary.isAcceptableOrUnknown(
          data['safe_summary']!,
          _safeSummaryMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_safeSummaryMeta);
    }
    if (data.containsKey('occurred_at')) {
      context.handle(
        _occurredAtMeta,
        occurredAt.isAcceptableOrUnknown(data['occurred_at']!, _occurredAtMeta),
      );
    } else if (isInserting) {
      context.missing(_occurredAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ActionLog map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ActionLog(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      ),
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      actionType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}action_type'],
      )!,
      result: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}result'],
      )!,
      safeSummary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}safe_summary'],
      )!,
      occurredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}occurred_at'],
      )!,
    );
  }

  @override
  $ActionLogsTable createAlias(String alias) {
    return $ActionLogsTable(attachedDatabase, alias);
  }
}

class ActionLog extends DataClass implements Insertable<ActionLog> {
  final String id;
  final String? accountId;
  final String source;
  final String actionType;
  final String result;
  final String safeSummary;
  final int occurredAt;
  const ActionLog({
    required this.id,
    this.accountId,
    required this.source,
    required this.actionType,
    required this.result,
    required this.safeSummary,
    required this.occurredAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || accountId != null) {
      map['account_id'] = Variable<String>(accountId);
    }
    map['source'] = Variable<String>(source);
    map['action_type'] = Variable<String>(actionType);
    map['result'] = Variable<String>(result);
    map['safe_summary'] = Variable<String>(safeSummary);
    map['occurred_at'] = Variable<int>(occurredAt);
    return map;
  }

  ActionLogsCompanion toCompanion(bool nullToAbsent) {
    return ActionLogsCompanion(
      id: Value(id),
      accountId: accountId == null && nullToAbsent
          ? const Value.absent()
          : Value(accountId),
      source: Value(source),
      actionType: Value(actionType),
      result: Value(result),
      safeSummary: Value(safeSummary),
      occurredAt: Value(occurredAt),
    );
  }

  factory ActionLog.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ActionLog(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String?>(json['accountId']),
      source: serializer.fromJson<String>(json['source']),
      actionType: serializer.fromJson<String>(json['actionType']),
      result: serializer.fromJson<String>(json['result']),
      safeSummary: serializer.fromJson<String>(json['safeSummary']),
      occurredAt: serializer.fromJson<int>(json['occurredAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String?>(accountId),
      'source': serializer.toJson<String>(source),
      'actionType': serializer.toJson<String>(actionType),
      'result': serializer.toJson<String>(result),
      'safeSummary': serializer.toJson<String>(safeSummary),
      'occurredAt': serializer.toJson<int>(occurredAt),
    };
  }

  ActionLog copyWith({
    String? id,
    Value<String?> accountId = const Value.absent(),
    String? source,
    String? actionType,
    String? result,
    String? safeSummary,
    int? occurredAt,
  }) => ActionLog(
    id: id ?? this.id,
    accountId: accountId.present ? accountId.value : this.accountId,
    source: source ?? this.source,
    actionType: actionType ?? this.actionType,
    result: result ?? this.result,
    safeSummary: safeSummary ?? this.safeSummary,
    occurredAt: occurredAt ?? this.occurredAt,
  );
  ActionLog copyWithCompanion(ActionLogsCompanion data) {
    return ActionLog(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      source: data.source.present ? data.source.value : this.source,
      actionType: data.actionType.present
          ? data.actionType.value
          : this.actionType,
      result: data.result.present ? data.result.value : this.result,
      safeSummary: data.safeSummary.present
          ? data.safeSummary.value
          : this.safeSummary,
      occurredAt: data.occurredAt.present
          ? data.occurredAt.value
          : this.occurredAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ActionLog(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('actionType: $actionType, ')
          ..write('result: $result, ')
          ..write('safeSummary: $safeSummary, ')
          ..write('occurredAt: $occurredAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    source,
    actionType,
    result,
    safeSummary,
    occurredAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ActionLog &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.source == this.source &&
          other.actionType == this.actionType &&
          other.result == this.result &&
          other.safeSummary == this.safeSummary &&
          other.occurredAt == this.occurredAt);
}

class ActionLogsCompanion extends UpdateCompanion<ActionLog> {
  final Value<String> id;
  final Value<String?> accountId;
  final Value<String> source;
  final Value<String> actionType;
  final Value<String> result;
  final Value<String> safeSummary;
  final Value<int> occurredAt;
  final Value<int> rowid;
  const ActionLogsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.source = const Value.absent(),
    this.actionType = const Value.absent(),
    this.result = const Value.absent(),
    this.safeSummary = const Value.absent(),
    this.occurredAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ActionLogsCompanion.insert({
    required String id,
    this.accountId = const Value.absent(),
    required String source,
    required String actionType,
    required String result,
    required String safeSummary,
    required int occurredAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       source = Value(source),
       actionType = Value(actionType),
       result = Value(result),
       safeSummary = Value(safeSummary),
       occurredAt = Value(occurredAt);
  static Insertable<ActionLog> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? source,
    Expression<String>? actionType,
    Expression<String>? result,
    Expression<String>? safeSummary,
    Expression<int>? occurredAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (source != null) 'source': source,
      if (actionType != null) 'action_type': actionType,
      if (result != null) 'result': result,
      if (safeSummary != null) 'safe_summary': safeSummary,
      if (occurredAt != null) 'occurred_at': occurredAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ActionLogsCompanion copyWith({
    Value<String>? id,
    Value<String?>? accountId,
    Value<String>? source,
    Value<String>? actionType,
    Value<String>? result,
    Value<String>? safeSummary,
    Value<int>? occurredAt,
    Value<int>? rowid,
  }) {
    return ActionLogsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      source: source ?? this.source,
      actionType: actionType ?? this.actionType,
      result: result ?? this.result,
      safeSummary: safeSummary ?? this.safeSummary,
      occurredAt: occurredAt ?? this.occurredAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (actionType.present) {
      map['action_type'] = Variable<String>(actionType.value);
    }
    if (result.present) {
      map['result'] = Variable<String>(result.value);
    }
    if (safeSummary.present) {
      map['safe_summary'] = Variable<String>(safeSummary.value);
    }
    if (occurredAt.present) {
      map['occurred_at'] = Variable<int>(occurredAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ActionLogsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('actionType: $actionType, ')
          ..write('result: $result, ')
          ..write('safeSummary: $safeSummary, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AgentPermissionPoliciesTable extends AgentPermissionPolicies
    with TableInfo<$AgentPermissionPoliciesTable, AgentPermissionPolicy> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AgentPermissionPoliciesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _actionTypeMeta = const VerificationMeta(
    'actionType',
  );
  @override
  late final GeneratedColumn<String> actionType = GeneratedColumn<String>(
    'action_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _policyMeta = const VerificationMeta('policy');
  @override
  late final GeneratedColumn<String> policy = GeneratedColumn<String>(
    'policy',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    actionType,
    policy,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'agent_permission_policies';
  @override
  VerificationContext validateIntegrity(
    Insertable<AgentPermissionPolicy> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('action_type')) {
      context.handle(
        _actionTypeMeta,
        actionType.isAcceptableOrUnknown(data['action_type']!, _actionTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_actionTypeMeta);
    }
    if (data.containsKey('policy')) {
      context.handle(
        _policyMeta,
        policy.isAcceptableOrUnknown(data['policy']!, _policyMeta),
      );
    } else if (isInserting) {
      context.missing(_policyMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, actionType},
  ];
  @override
  AgentPermissionPolicy map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AgentPermissionPolicy(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      actionType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}action_type'],
      )!,
      policy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}policy'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $AgentPermissionPoliciesTable createAlias(String alias) {
    return $AgentPermissionPoliciesTable(attachedDatabase, alias);
  }
}

class AgentPermissionPolicy extends DataClass
    implements Insertable<AgentPermissionPolicy> {
  final String id;
  final String accountId;
  final String actionType;
  final String policy;
  final int updatedAt;
  const AgentPermissionPolicy({
    required this.id,
    required this.accountId,
    required this.actionType,
    required this.policy,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['action_type'] = Variable<String>(actionType);
    map['policy'] = Variable<String>(policy);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  AgentPermissionPoliciesCompanion toCompanion(bool nullToAbsent) {
    return AgentPermissionPoliciesCompanion(
      id: Value(id),
      accountId: Value(accountId),
      actionType: Value(actionType),
      policy: Value(policy),
      updatedAt: Value(updatedAt),
    );
  }

  factory AgentPermissionPolicy.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AgentPermissionPolicy(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      actionType: serializer.fromJson<String>(json['actionType']),
      policy: serializer.fromJson<String>(json['policy']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'actionType': serializer.toJson<String>(actionType),
      'policy': serializer.toJson<String>(policy),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  AgentPermissionPolicy copyWith({
    String? id,
    String? accountId,
    String? actionType,
    String? policy,
    int? updatedAt,
  }) => AgentPermissionPolicy(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    actionType: actionType ?? this.actionType,
    policy: policy ?? this.policy,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  AgentPermissionPolicy copyWithCompanion(
    AgentPermissionPoliciesCompanion data,
  ) {
    return AgentPermissionPolicy(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      actionType: data.actionType.present
          ? data.actionType.value
          : this.actionType,
      policy: data.policy.present ? data.policy.value : this.policy,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AgentPermissionPolicy(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('actionType: $actionType, ')
          ..write('policy: $policy, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, accountId, actionType, policy, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AgentPermissionPolicy &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.actionType == this.actionType &&
          other.policy == this.policy &&
          other.updatedAt == this.updatedAt);
}

class AgentPermissionPoliciesCompanion
    extends UpdateCompanion<AgentPermissionPolicy> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> actionType;
  final Value<String> policy;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const AgentPermissionPoliciesCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.actionType = const Value.absent(),
    this.policy = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AgentPermissionPoliciesCompanion.insert({
    required String id,
    required String accountId,
    required String actionType,
    required String policy,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       actionType = Value(actionType),
       policy = Value(policy),
       updatedAt = Value(updatedAt);
  static Insertable<AgentPermissionPolicy> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? actionType,
    Expression<String>? policy,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (actionType != null) 'action_type': actionType,
      if (policy != null) 'policy': policy,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AgentPermissionPoliciesCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? actionType,
    Value<String>? policy,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return AgentPermissionPoliciesCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      actionType: actionType ?? this.actionType,
      policy: policy ?? this.policy,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (actionType.present) {
      map['action_type'] = Variable<String>(actionType.value);
    }
    if (policy.present) {
      map['policy'] = Variable<String>(policy.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AgentPermissionPoliciesCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('actionType: $actionType, ')
          ..write('policy: $policy, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $LocalAccountsTable localAccounts = $LocalAccountsTable(this);
  late final $CredentialAccountsTable credentialAccounts =
      $CredentialAccountsTable(this);
  late final $SourceConfigsTable sourceConfigs = $SourceConfigsTable(this);
  late final $ImportBatchesTable importBatches = $ImportBatchesTable(this);
  late final $SourceRecordsTable sourceRecords = $SourceRecordsTable(this);
  late final $SyncRunsTable syncRuns = $SyncRunsTable(this);
  late final $ActionLogsTable actionLogs = $ActionLogsTable(this);
  late final $AgentPermissionPoliciesTable agentPermissionPolicies =
      $AgentPermissionPoliciesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    localAccounts,
    credentialAccounts,
    sourceConfigs,
    importBatches,
    sourceRecords,
    syncRuns,
    actionLogs,
    agentPermissionPolicies,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('credential_accounts', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('source_configs', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('import_batches', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('source_records', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('sync_runs', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'import_batches',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('sync_runs', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('action_logs', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [
        TableUpdate('agent_permission_policies', kind: UpdateKind.delete),
      ],
    ),
  ]);
}

typedef $$LocalAccountsTableCreateCompanionBuilder =
    LocalAccountsCompanion Function({
      required String id,
      required String maskedHint,
      Value<bool> isActive,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$LocalAccountsTableUpdateCompanionBuilder =
    LocalAccountsCompanion Function({
      Value<String> id,
      Value<String> maskedHint,
      Value<bool> isActive,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$LocalAccountsTableReferences
    extends BaseReferences<_$AppDatabase, $LocalAccountsTable, LocalAccount> {
  $$LocalAccountsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$CredentialAccountsTable, List<CredentialAccount>>
  _credentialAccountsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.credentialAccounts,
        aliasName: 'local_accounts__id__credential_accounts__account_id',
      );

  $$CredentialAccountsTableProcessedTableManager get credentialAccountsRefs {
    final manager = $$CredentialAccountsTableTableManager(
      $_db,
      $_db.credentialAccounts,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _credentialAccountsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$SourceConfigsTable, List<SourceConfig>>
  _sourceConfigsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.sourceConfigs,
    aliasName: 'local_accounts__id__source_configs__account_id',
  );

  $$SourceConfigsTableProcessedTableManager get sourceConfigsRefs {
    final manager = $$SourceConfigsTableTableManager(
      $_db,
      $_db.sourceConfigs,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_sourceConfigsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ImportBatchesTable, List<ImportBatche>>
  _importBatchesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.importBatches,
    aliasName: 'local_accounts__id__import_batches__account_id',
  );

  $$ImportBatchesTableProcessedTableManager get importBatchesRefs {
    final manager = $$ImportBatchesTableTableManager(
      $_db,
      $_db.importBatches,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_importBatchesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$SourceRecordsTable, List<SourceRecord>>
  _sourceRecordsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.sourceRecords,
    aliasName: 'local_accounts__id__source_records__account_id',
  );

  $$SourceRecordsTableProcessedTableManager get sourceRecordsRefs {
    final manager = $$SourceRecordsTableTableManager(
      $_db,
      $_db.sourceRecords,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_sourceRecordsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$SyncRunsTable, List<SyncRun>> _syncRunsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.syncRuns,
    aliasName: 'local_accounts__id__sync_runs__account_id',
  );

  $$SyncRunsTableProcessedTableManager get syncRunsRefs {
    final manager = $$SyncRunsTableTableManager(
      $_db,
      $_db.syncRuns,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_syncRunsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ActionLogsTable, List<ActionLog>>
  _actionLogsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.actionLogs,
    aliasName: 'local_accounts__id__action_logs__account_id',
  );

  $$ActionLogsTableProcessedTableManager get actionLogsRefs {
    final manager = $$ActionLogsTableTableManager(
      $_db,
      $_db.actionLogs,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_actionLogsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $AgentPermissionPoliciesTable,
    List<AgentPermissionPolicy>
  >
  _agentPermissionPoliciesRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.agentPermissionPolicies,
        aliasName: 'local_accounts__id__agent_permission_policies__account_id',
      );

  $$AgentPermissionPoliciesTableProcessedTableManager
  get agentPermissionPoliciesRefs {
    final manager = $$AgentPermissionPoliciesTableTableManager(
      $_db,
      $_db.agentPermissionPolicies,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _agentPermissionPoliciesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$LocalAccountsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalAccountsTable> {
  $$LocalAccountsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get maskedHint => $composableBuilder(
    column: $table.maskedHint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> credentialAccountsRefs(
    Expression<bool> Function($$CredentialAccountsTableFilterComposer f) f,
  ) {
    final $$CredentialAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.credentialAccounts,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CredentialAccountsTableFilterComposer(
            $db: $db,
            $table: $db.credentialAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> sourceConfigsRefs(
    Expression<bool> Function($$SourceConfigsTableFilterComposer f) f,
  ) {
    final $$SourceConfigsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sourceConfigs,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SourceConfigsTableFilterComposer(
            $db: $db,
            $table: $db.sourceConfigs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> importBatchesRefs(
    Expression<bool> Function($$ImportBatchesTableFilterComposer f) f,
  ) {
    final $$ImportBatchesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.importBatches,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ImportBatchesTableFilterComposer(
            $db: $db,
            $table: $db.importBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> sourceRecordsRefs(
    Expression<bool> Function($$SourceRecordsTableFilterComposer f) f,
  ) {
    final $$SourceRecordsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sourceRecords,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SourceRecordsTableFilterComposer(
            $db: $db,
            $table: $db.sourceRecords,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> syncRunsRefs(
    Expression<bool> Function($$SyncRunsTableFilterComposer f) f,
  ) {
    final $$SyncRunsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncRuns,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncRunsTableFilterComposer(
            $db: $db,
            $table: $db.syncRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> actionLogsRefs(
    Expression<bool> Function($$ActionLogsTableFilterComposer f) f,
  ) {
    final $$ActionLogsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.actionLogs,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ActionLogsTableFilterComposer(
            $db: $db,
            $table: $db.actionLogs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> agentPermissionPoliciesRefs(
    Expression<bool> Function($$AgentPermissionPoliciesTableFilterComposer f) f,
  ) {
    final $$AgentPermissionPoliciesTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.agentPermissionPolicies,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$AgentPermissionPoliciesTableFilterComposer(
                $db: $db,
                $table: $db.agentPermissionPolicies,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$LocalAccountsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalAccountsTable> {
  $$LocalAccountsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get maskedHint => $composableBuilder(
    column: $table.maskedHint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalAccountsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalAccountsTable> {
  $$LocalAccountsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get maskedHint => $composableBuilder(
    column: $table.maskedHint,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> credentialAccountsRefs<T extends Object>(
    Expression<T> Function($$CredentialAccountsTableAnnotationComposer a) f,
  ) {
    final $$CredentialAccountsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.credentialAccounts,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CredentialAccountsTableAnnotationComposer(
                $db: $db,
                $table: $db.credentialAccounts,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> sourceConfigsRefs<T extends Object>(
    Expression<T> Function($$SourceConfigsTableAnnotationComposer a) f,
  ) {
    final $$SourceConfigsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sourceConfigs,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SourceConfigsTableAnnotationComposer(
            $db: $db,
            $table: $db.sourceConfigs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> importBatchesRefs<T extends Object>(
    Expression<T> Function($$ImportBatchesTableAnnotationComposer a) f,
  ) {
    final $$ImportBatchesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.importBatches,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ImportBatchesTableAnnotationComposer(
            $db: $db,
            $table: $db.importBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> sourceRecordsRefs<T extends Object>(
    Expression<T> Function($$SourceRecordsTableAnnotationComposer a) f,
  ) {
    final $$SourceRecordsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sourceRecords,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SourceRecordsTableAnnotationComposer(
            $db: $db,
            $table: $db.sourceRecords,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> syncRunsRefs<T extends Object>(
    Expression<T> Function($$SyncRunsTableAnnotationComposer a) f,
  ) {
    final $$SyncRunsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncRuns,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncRunsTableAnnotationComposer(
            $db: $db,
            $table: $db.syncRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> actionLogsRefs<T extends Object>(
    Expression<T> Function($$ActionLogsTableAnnotationComposer a) f,
  ) {
    final $$ActionLogsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.actionLogs,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ActionLogsTableAnnotationComposer(
            $db: $db,
            $table: $db.actionLogs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> agentPermissionPoliciesRefs<T extends Object>(
    Expression<T> Function($$AgentPermissionPoliciesTableAnnotationComposer a)
    f,
  ) {
    final $$AgentPermissionPoliciesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.agentPermissionPolicies,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$AgentPermissionPoliciesTableAnnotationComposer(
                $db: $db,
                $table: $db.agentPermissionPolicies,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$LocalAccountsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalAccountsTable,
          LocalAccount,
          $$LocalAccountsTableFilterComposer,
          $$LocalAccountsTableOrderingComposer,
          $$LocalAccountsTableAnnotationComposer,
          $$LocalAccountsTableCreateCompanionBuilder,
          $$LocalAccountsTableUpdateCompanionBuilder,
          (LocalAccount, $$LocalAccountsTableReferences),
          LocalAccount,
          PrefetchHooks Function({
            bool credentialAccountsRefs,
            bool sourceConfigsRefs,
            bool importBatchesRefs,
            bool sourceRecordsRefs,
            bool syncRunsRefs,
            bool actionLogsRefs,
            bool agentPermissionPoliciesRefs,
          })
        > {
  $$LocalAccountsTableTableManager(_$AppDatabase db, $LocalAccountsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalAccountsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalAccountsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalAccountsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> maskedHint = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalAccountsCompanion(
                id: id,
                maskedHint: maskedHint,
                isActive: isActive,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String maskedHint,
                Value<bool> isActive = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => LocalAccountsCompanion.insert(
                id: id,
                maskedHint: maskedHint,
                isActive: isActive,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LocalAccountsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                credentialAccountsRefs = false,
                sourceConfigsRefs = false,
                importBatchesRefs = false,
                sourceRecordsRefs = false,
                syncRunsRefs = false,
                actionLogsRefs = false,
                agentPermissionPoliciesRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (credentialAccountsRefs) db.credentialAccounts,
                    if (sourceConfigsRefs) db.sourceConfigs,
                    if (importBatchesRefs) db.importBatches,
                    if (sourceRecordsRefs) db.sourceRecords,
                    if (syncRunsRefs) db.syncRuns,
                    if (actionLogsRefs) db.actionLogs,
                    if (agentPermissionPoliciesRefs) db.agentPermissionPolicies,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (credentialAccountsRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          CredentialAccount
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._credentialAccountsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).credentialAccountsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (sourceConfigsRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          SourceConfig
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._sourceConfigsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).sourceConfigsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (importBatchesRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          ImportBatche
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._importBatchesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).importBatchesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (sourceRecordsRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          SourceRecord
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._sourceRecordsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).sourceRecordsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (syncRunsRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          SyncRun
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._syncRunsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).syncRunsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (actionLogsRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          ActionLog
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._actionLogsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).actionLogsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (agentPermissionPoliciesRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          AgentPermissionPolicy
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._agentPermissionPoliciesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).agentPermissionPoliciesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$LocalAccountsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalAccountsTable,
      LocalAccount,
      $$LocalAccountsTableFilterComposer,
      $$LocalAccountsTableOrderingComposer,
      $$LocalAccountsTableAnnotationComposer,
      $$LocalAccountsTableCreateCompanionBuilder,
      $$LocalAccountsTableUpdateCompanionBuilder,
      (LocalAccount, $$LocalAccountsTableReferences),
      LocalAccount,
      PrefetchHooks Function({
        bool credentialAccountsRefs,
        bool sourceConfigsRefs,
        bool importBatchesRefs,
        bool sourceRecordsRefs,
        bool syncRunsRefs,
        bool actionLogsRefs,
        bool agentPermissionPoliciesRefs,
      })
    >;
typedef $$CredentialAccountsTableCreateCompanionBuilder =
    CredentialAccountsCompanion Function({
      required String accountId,
      required Uint8List usernameCiphertext,
      Value<Uint8List?> passwordCiphertext,
      required String scheme,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$CredentialAccountsTableUpdateCompanionBuilder =
    CredentialAccountsCompanion Function({
      Value<String> accountId,
      Value<Uint8List> usernameCiphertext,
      Value<Uint8List?> passwordCiphertext,
      Value<String> scheme,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$CredentialAccountsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $CredentialAccountsTable,
          CredentialAccount
        > {
  $$CredentialAccountsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('credential_accounts__account_id__local_accounts__id');

  $$LocalAccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$LocalAccountsTableTableManager(
      $_db,
      $_db.localAccounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CredentialAccountsTableFilterComposer
    extends Composer<_$AppDatabase, $CredentialAccountsTable> {
  $$CredentialAccountsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<Uint8List> get usernameCiphertext => $composableBuilder(
    column: $table.usernameCiphertext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get passwordCiphertext => $composableBuilder(
    column: $table.passwordCiphertext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scheme => $composableBuilder(
    column: $table.scheme,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalAccountsTableFilterComposer get accountId {
    final $$LocalAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableFilterComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CredentialAccountsTableOrderingComposer
    extends Composer<_$AppDatabase, $CredentialAccountsTable> {
  $$CredentialAccountsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<Uint8List> get usernameCiphertext => $composableBuilder(
    column: $table.usernameCiphertext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get passwordCiphertext => $composableBuilder(
    column: $table.passwordCiphertext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scheme => $composableBuilder(
    column: $table.scheme,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalAccountsTableOrderingComposer get accountId {
    final $$LocalAccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableOrderingComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CredentialAccountsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CredentialAccountsTable> {
  $$CredentialAccountsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<Uint8List> get usernameCiphertext => $composableBuilder(
    column: $table.usernameCiphertext,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get passwordCiphertext => $composableBuilder(
    column: $table.passwordCiphertext,
    builder: (column) => column,
  );

  GeneratedColumn<String> get scheme =>
      $composableBuilder(column: $table.scheme, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$LocalAccountsTableAnnotationComposer get accountId {
    final $$LocalAccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CredentialAccountsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CredentialAccountsTable,
          CredentialAccount,
          $$CredentialAccountsTableFilterComposer,
          $$CredentialAccountsTableOrderingComposer,
          $$CredentialAccountsTableAnnotationComposer,
          $$CredentialAccountsTableCreateCompanionBuilder,
          $$CredentialAccountsTableUpdateCompanionBuilder,
          (CredentialAccount, $$CredentialAccountsTableReferences),
          CredentialAccount,
          PrefetchHooks Function({bool accountId})
        > {
  $$CredentialAccountsTableTableManager(
    _$AppDatabase db,
    $CredentialAccountsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CredentialAccountsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CredentialAccountsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CredentialAccountsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<Uint8List> usernameCiphertext = const Value.absent(),
                Value<Uint8List?> passwordCiphertext = const Value.absent(),
                Value<String> scheme = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CredentialAccountsCompanion(
                accountId: accountId,
                usernameCiphertext: usernameCiphertext,
                passwordCiphertext: passwordCiphertext,
                scheme: scheme,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required Uint8List usernameCiphertext,
                Value<Uint8List?> passwordCiphertext = const Value.absent(),
                required String scheme,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => CredentialAccountsCompanion.insert(
                accountId: accountId,
                usernameCiphertext: usernameCiphertext,
                passwordCiphertext: passwordCiphertext,
                scheme: scheme,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CredentialAccountsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable:
                                    $$CredentialAccountsTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$CredentialAccountsTableReferences
                                        ._accountIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CredentialAccountsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CredentialAccountsTable,
      CredentialAccount,
      $$CredentialAccountsTableFilterComposer,
      $$CredentialAccountsTableOrderingComposer,
      $$CredentialAccountsTableAnnotationComposer,
      $$CredentialAccountsTableCreateCompanionBuilder,
      $$CredentialAccountsTableUpdateCompanionBuilder,
      (CredentialAccount, $$CredentialAccountsTableReferences),
      CredentialAccount,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$SourceConfigsTableCreateCompanionBuilder =
    SourceConfigsCompanion Function({
      required String id,
      required String accountId,
      required String source,
      Value<bool> enabled,
      Value<String> configJson,
      Value<int?> lastSuccessAt,
      Value<int?> retryAfter,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$SourceConfigsTableUpdateCompanionBuilder =
    SourceConfigsCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> source,
      Value<bool> enabled,
      Value<String> configJson,
      Value<int?> lastSuccessAt,
      Value<int?> retryAfter,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$SourceConfigsTableReferences
    extends BaseReferences<_$AppDatabase, $SourceConfigsTable, SourceConfig> {
  $$SourceConfigsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('source_configs__account_id__local_accounts__id');

  $$LocalAccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$LocalAccountsTableTableManager(
      $_db,
      $_db.localAccounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SourceConfigsTableFilterComposer
    extends Composer<_$AppDatabase, $SourceConfigsTable> {
  $$SourceConfigsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSuccessAt => $composableBuilder(
    column: $table.lastSuccessAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get retryAfter => $composableBuilder(
    column: $table.retryAfter,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalAccountsTableFilterComposer get accountId {
    final $$LocalAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableFilterComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SourceConfigsTableOrderingComposer
    extends Composer<_$AppDatabase, $SourceConfigsTable> {
  $$SourceConfigsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSuccessAt => $composableBuilder(
    column: $table.lastSuccessAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get retryAfter => $composableBuilder(
    column: $table.retryAfter,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalAccountsTableOrderingComposer get accountId {
    final $$LocalAccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableOrderingComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SourceConfigsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SourceConfigsTable> {
  $$SourceConfigsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastSuccessAt => $composableBuilder(
    column: $table.lastSuccessAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get retryAfter => $composableBuilder(
    column: $table.retryAfter,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$LocalAccountsTableAnnotationComposer get accountId {
    final $$LocalAccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SourceConfigsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SourceConfigsTable,
          SourceConfig,
          $$SourceConfigsTableFilterComposer,
          $$SourceConfigsTableOrderingComposer,
          $$SourceConfigsTableAnnotationComposer,
          $$SourceConfigsTableCreateCompanionBuilder,
          $$SourceConfigsTableUpdateCompanionBuilder,
          (SourceConfig, $$SourceConfigsTableReferences),
          SourceConfig,
          PrefetchHooks Function({bool accountId})
        > {
  $$SourceConfigsTableTableManager(_$AppDatabase db, $SourceConfigsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SourceConfigsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SourceConfigsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SourceConfigsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<String> configJson = const Value.absent(),
                Value<int?> lastSuccessAt = const Value.absent(),
                Value<int?> retryAfter = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourceConfigsCompanion(
                id: id,
                accountId: accountId,
                source: source,
                enabled: enabled,
                configJson: configJson,
                lastSuccessAt: lastSuccessAt,
                retryAfter: retryAfter,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String source,
                Value<bool> enabled = const Value.absent(),
                Value<String> configJson = const Value.absent(),
                Value<int?> lastSuccessAt = const Value.absent(),
                Value<int?> retryAfter = const Value.absent(),
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => SourceConfigsCompanion.insert(
                id: id,
                accountId: accountId,
                source: source,
                enabled: enabled,
                configJson: configJson,
                lastSuccessAt: lastSuccessAt,
                retryAfter: retryAfter,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SourceConfigsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable: $$SourceConfigsTableReferences
                                    ._accountIdTable(db),
                                referencedColumn: $$SourceConfigsTableReferences
                                    ._accountIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$SourceConfigsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SourceConfigsTable,
      SourceConfig,
      $$SourceConfigsTableFilterComposer,
      $$SourceConfigsTableOrderingComposer,
      $$SourceConfigsTableAnnotationComposer,
      $$SourceConfigsTableCreateCompanionBuilder,
      $$SourceConfigsTableUpdateCompanionBuilder,
      (SourceConfig, $$SourceConfigsTableReferences),
      SourceConfig,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$ImportBatchesTableCreateCompanionBuilder =
    ImportBatchesCompanion Function({
      required String id,
      required String accountId,
      required String bundleId,
      required String digest,
      required String source,
      required String scopeKey,
      required int importedAt,
      required String origin,
      Value<int> rowid,
    });
typedef $$ImportBatchesTableUpdateCompanionBuilder =
    ImportBatchesCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> bundleId,
      Value<String> digest,
      Value<String> source,
      Value<String> scopeKey,
      Value<int> importedAt,
      Value<String> origin,
      Value<int> rowid,
    });

final class $$ImportBatchesTableReferences
    extends BaseReferences<_$AppDatabase, $ImportBatchesTable, ImportBatche> {
  $$ImportBatchesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('import_batches__account_id__local_accounts__id');

  $$LocalAccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$LocalAccountsTableTableManager(
      $_db,
      $_db.localAccounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$SourceRecordsTable, List<SourceRecord>>
  _sourceRecordsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.sourceRecords,
    aliasName: 'import_batches__id__source_records__import_batch_id',
  );

  $$SourceRecordsTableProcessedTableManager get sourceRecordsRefs {
    final manager = $$SourceRecordsTableTableManager(
      $_db,
      $_db.sourceRecords,
    ).filter((f) => f.importBatchId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_sourceRecordsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$SyncRunsTable, List<SyncRun>> _syncRunsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.syncRuns,
    aliasName: 'import_batches__id__sync_runs__import_batch_id',
  );

  $$SyncRunsTableProcessedTableManager get syncRunsRefs {
    final manager = $$SyncRunsTableTableManager(
      $_db,
      $_db.syncRuns,
    ).filter((f) => f.importBatchId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_syncRunsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ImportBatchesTableFilterComposer
    extends Composer<_$AppDatabase, $ImportBatchesTable> {
  $$ImportBatchesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bundleId => $composableBuilder(
    column: $table.bundleId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get digest => $composableBuilder(
    column: $table.digest,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get importedAt => $composableBuilder(
    column: $table.importedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalAccountsTableFilterComposer get accountId {
    final $$LocalAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableFilterComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> sourceRecordsRefs(
    Expression<bool> Function($$SourceRecordsTableFilterComposer f) f,
  ) {
    final $$SourceRecordsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sourceRecords,
      getReferencedColumn: (t) => t.importBatchId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SourceRecordsTableFilterComposer(
            $db: $db,
            $table: $db.sourceRecords,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> syncRunsRefs(
    Expression<bool> Function($$SyncRunsTableFilterComposer f) f,
  ) {
    final $$SyncRunsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncRuns,
      getReferencedColumn: (t) => t.importBatchId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncRunsTableFilterComposer(
            $db: $db,
            $table: $db.syncRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ImportBatchesTableOrderingComposer
    extends Composer<_$AppDatabase, $ImportBatchesTable> {
  $$ImportBatchesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bundleId => $composableBuilder(
    column: $table.bundleId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get digest => $composableBuilder(
    column: $table.digest,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get importedAt => $composableBuilder(
    column: $table.importedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalAccountsTableOrderingComposer get accountId {
    final $$LocalAccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableOrderingComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ImportBatchesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ImportBatchesTable> {
  $$ImportBatchesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get bundleId =>
      $composableBuilder(column: $table.bundleId, builder: (column) => column);

  GeneratedColumn<String> get digest =>
      $composableBuilder(column: $table.digest, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get scopeKey =>
      $composableBuilder(column: $table.scopeKey, builder: (column) => column);

  GeneratedColumn<int> get importedAt => $composableBuilder(
    column: $table.importedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get origin =>
      $composableBuilder(column: $table.origin, builder: (column) => column);

  $$LocalAccountsTableAnnotationComposer get accountId {
    final $$LocalAccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> sourceRecordsRefs<T extends Object>(
    Expression<T> Function($$SourceRecordsTableAnnotationComposer a) f,
  ) {
    final $$SourceRecordsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sourceRecords,
      getReferencedColumn: (t) => t.importBatchId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SourceRecordsTableAnnotationComposer(
            $db: $db,
            $table: $db.sourceRecords,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> syncRunsRefs<T extends Object>(
    Expression<T> Function($$SyncRunsTableAnnotationComposer a) f,
  ) {
    final $$SyncRunsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncRuns,
      getReferencedColumn: (t) => t.importBatchId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncRunsTableAnnotationComposer(
            $db: $db,
            $table: $db.syncRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ImportBatchesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ImportBatchesTable,
          ImportBatche,
          $$ImportBatchesTableFilterComposer,
          $$ImportBatchesTableOrderingComposer,
          $$ImportBatchesTableAnnotationComposer,
          $$ImportBatchesTableCreateCompanionBuilder,
          $$ImportBatchesTableUpdateCompanionBuilder,
          (ImportBatche, $$ImportBatchesTableReferences),
          ImportBatche,
          PrefetchHooks Function({
            bool accountId,
            bool sourceRecordsRefs,
            bool syncRunsRefs,
          })
        > {
  $$ImportBatchesTableTableManager(_$AppDatabase db, $ImportBatchesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ImportBatchesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ImportBatchesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ImportBatchesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> bundleId = const Value.absent(),
                Value<String> digest = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> scopeKey = const Value.absent(),
                Value<int> importedAt = const Value.absent(),
                Value<String> origin = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ImportBatchesCompanion(
                id: id,
                accountId: accountId,
                bundleId: bundleId,
                digest: digest,
                source: source,
                scopeKey: scopeKey,
                importedAt: importedAt,
                origin: origin,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String bundleId,
                required String digest,
                required String source,
                required String scopeKey,
                required int importedAt,
                required String origin,
                Value<int> rowid = const Value.absent(),
              }) => ImportBatchesCompanion.insert(
                id: id,
                accountId: accountId,
                bundleId: bundleId,
                digest: digest,
                source: source,
                scopeKey: scopeKey,
                importedAt: importedAt,
                origin: origin,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ImportBatchesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                accountId = false,
                sourceRecordsRefs = false,
                syncRunsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (sourceRecordsRefs) db.sourceRecords,
                    if (syncRunsRefs) db.syncRuns,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (accountId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.accountId,
                                    referencedTable:
                                        $$ImportBatchesTableReferences
                                            ._accountIdTable(db),
                                    referencedColumn:
                                        $$ImportBatchesTableReferences
                                            ._accountIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (sourceRecordsRefs)
                        await $_getPrefetchedData<
                          ImportBatche,
                          $ImportBatchesTable,
                          SourceRecord
                        >(
                          currentTable: table,
                          referencedTable: $$ImportBatchesTableReferences
                              ._sourceRecordsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ImportBatchesTableReferences(
                                db,
                                table,
                                p0,
                              ).sourceRecordsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.importBatchId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (syncRunsRefs)
                        await $_getPrefetchedData<
                          ImportBatche,
                          $ImportBatchesTable,
                          SyncRun
                        >(
                          currentTable: table,
                          referencedTable: $$ImportBatchesTableReferences
                              ._syncRunsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ImportBatchesTableReferences(
                                db,
                                table,
                                p0,
                              ).syncRunsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.importBatchId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$ImportBatchesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ImportBatchesTable,
      ImportBatche,
      $$ImportBatchesTableFilterComposer,
      $$ImportBatchesTableOrderingComposer,
      $$ImportBatchesTableAnnotationComposer,
      $$ImportBatchesTableCreateCompanionBuilder,
      $$ImportBatchesTableUpdateCompanionBuilder,
      (ImportBatche, $$ImportBatchesTableReferences),
      ImportBatche,
      PrefetchHooks Function({
        bool accountId,
        bool sourceRecordsRefs,
        bool syncRunsRefs,
      })
    >;
typedef $$SourceRecordsTableCreateCompanionBuilder =
    SourceRecordsCompanion Function({
      required String id,
      required String accountId,
      required String source,
      required String entityType,
      required String externalId,
      required String localEntityId,
      required String sourceStatus,
      required String presence,
      required String scopeKey,
      Value<String?> importBatchId,
      Value<int?> sourceUpdatedAt,
      required int firstObservedAt,
      required int lastObservedAt,
      Value<int> rowid,
    });
typedef $$SourceRecordsTableUpdateCompanionBuilder =
    SourceRecordsCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> source,
      Value<String> entityType,
      Value<String> externalId,
      Value<String> localEntityId,
      Value<String> sourceStatus,
      Value<String> presence,
      Value<String> scopeKey,
      Value<String?> importBatchId,
      Value<int?> sourceUpdatedAt,
      Value<int> firstObservedAt,
      Value<int> lastObservedAt,
      Value<int> rowid,
    });

final class $$SourceRecordsTableReferences
    extends BaseReferences<_$AppDatabase, $SourceRecordsTable, SourceRecord> {
  $$SourceRecordsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('source_records__account_id__local_accounts__id');

  $$LocalAccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$LocalAccountsTableTableManager(
      $_db,
      $_db.localAccounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $ImportBatchesTable _importBatchIdTable(_$AppDatabase db) => db
      .importBatches
      .createAlias('source_records__import_batch_id__import_batches__id');

  $$ImportBatchesTableProcessedTableManager? get importBatchId {
    final $_column = $_itemColumn<String>('import_batch_id');
    if ($_column == null) return null;
    final manager = $$ImportBatchesTableTableManager(
      $_db,
      $_db.importBatches,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_importBatchIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SourceRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $SourceRecordsTable> {
  $$SourceRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localEntityId => $composableBuilder(
    column: $table.localEntityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceStatus => $composableBuilder(
    column: $table.sourceStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get presence => $composableBuilder(
    column: $table.presence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sourceUpdatedAt => $composableBuilder(
    column: $table.sourceUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get firstObservedAt => $composableBuilder(
    column: $table.firstObservedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastObservedAt => $composableBuilder(
    column: $table.lastObservedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalAccountsTableFilterComposer get accountId {
    final $$LocalAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableFilterComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ImportBatchesTableFilterComposer get importBatchId {
    final $$ImportBatchesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.importBatchId,
      referencedTable: $db.importBatches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ImportBatchesTableFilterComposer(
            $db: $db,
            $table: $db.importBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SourceRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $SourceRecordsTable> {
  $$SourceRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localEntityId => $composableBuilder(
    column: $table.localEntityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceStatus => $composableBuilder(
    column: $table.sourceStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get presence => $composableBuilder(
    column: $table.presence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sourceUpdatedAt => $composableBuilder(
    column: $table.sourceUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get firstObservedAt => $composableBuilder(
    column: $table.firstObservedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastObservedAt => $composableBuilder(
    column: $table.lastObservedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalAccountsTableOrderingComposer get accountId {
    final $$LocalAccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableOrderingComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ImportBatchesTableOrderingComposer get importBatchId {
    final $$ImportBatchesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.importBatchId,
      referencedTable: $db.importBatches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ImportBatchesTableOrderingComposer(
            $db: $db,
            $table: $db.importBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SourceRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SourceRecordsTable> {
  $$SourceRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get localEntityId => $composableBuilder(
    column: $table.localEntityId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceStatus => $composableBuilder(
    column: $table.sourceStatus,
    builder: (column) => column,
  );

  GeneratedColumn<String> get presence =>
      $composableBuilder(column: $table.presence, builder: (column) => column);

  GeneratedColumn<String> get scopeKey =>
      $composableBuilder(column: $table.scopeKey, builder: (column) => column);

  GeneratedColumn<int> get sourceUpdatedAt => $composableBuilder(
    column: $table.sourceUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get firstObservedAt => $composableBuilder(
    column: $table.firstObservedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastObservedAt => $composableBuilder(
    column: $table.lastObservedAt,
    builder: (column) => column,
  );

  $$LocalAccountsTableAnnotationComposer get accountId {
    final $$LocalAccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ImportBatchesTableAnnotationComposer get importBatchId {
    final $$ImportBatchesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.importBatchId,
      referencedTable: $db.importBatches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ImportBatchesTableAnnotationComposer(
            $db: $db,
            $table: $db.importBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SourceRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SourceRecordsTable,
          SourceRecord,
          $$SourceRecordsTableFilterComposer,
          $$SourceRecordsTableOrderingComposer,
          $$SourceRecordsTableAnnotationComposer,
          $$SourceRecordsTableCreateCompanionBuilder,
          $$SourceRecordsTableUpdateCompanionBuilder,
          (SourceRecord, $$SourceRecordsTableReferences),
          SourceRecord,
          PrefetchHooks Function({bool accountId, bool importBatchId})
        > {
  $$SourceRecordsTableTableManager(_$AppDatabase db, $SourceRecordsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SourceRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SourceRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SourceRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> entityType = const Value.absent(),
                Value<String> externalId = const Value.absent(),
                Value<String> localEntityId = const Value.absent(),
                Value<String> sourceStatus = const Value.absent(),
                Value<String> presence = const Value.absent(),
                Value<String> scopeKey = const Value.absent(),
                Value<String?> importBatchId = const Value.absent(),
                Value<int?> sourceUpdatedAt = const Value.absent(),
                Value<int> firstObservedAt = const Value.absent(),
                Value<int> lastObservedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourceRecordsCompanion(
                id: id,
                accountId: accountId,
                source: source,
                entityType: entityType,
                externalId: externalId,
                localEntityId: localEntityId,
                sourceStatus: sourceStatus,
                presence: presence,
                scopeKey: scopeKey,
                importBatchId: importBatchId,
                sourceUpdatedAt: sourceUpdatedAt,
                firstObservedAt: firstObservedAt,
                lastObservedAt: lastObservedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String source,
                required String entityType,
                required String externalId,
                required String localEntityId,
                required String sourceStatus,
                required String presence,
                required String scopeKey,
                Value<String?> importBatchId = const Value.absent(),
                Value<int?> sourceUpdatedAt = const Value.absent(),
                required int firstObservedAt,
                required int lastObservedAt,
                Value<int> rowid = const Value.absent(),
              }) => SourceRecordsCompanion.insert(
                id: id,
                accountId: accountId,
                source: source,
                entityType: entityType,
                externalId: externalId,
                localEntityId: localEntityId,
                sourceStatus: sourceStatus,
                presence: presence,
                scopeKey: scopeKey,
                importBatchId: importBatchId,
                sourceUpdatedAt: sourceUpdatedAt,
                firstObservedAt: firstObservedAt,
                lastObservedAt: lastObservedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SourceRecordsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false, importBatchId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable: $$SourceRecordsTableReferences
                                    ._accountIdTable(db),
                                referencedColumn: $$SourceRecordsTableReferences
                                    ._accountIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (importBatchId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.importBatchId,
                                referencedTable: $$SourceRecordsTableReferences
                                    ._importBatchIdTable(db),
                                referencedColumn: $$SourceRecordsTableReferences
                                    ._importBatchIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$SourceRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SourceRecordsTable,
      SourceRecord,
      $$SourceRecordsTableFilterComposer,
      $$SourceRecordsTableOrderingComposer,
      $$SourceRecordsTableAnnotationComposer,
      $$SourceRecordsTableCreateCompanionBuilder,
      $$SourceRecordsTableUpdateCompanionBuilder,
      (SourceRecord, $$SourceRecordsTableReferences),
      SourceRecord,
      PrefetchHooks Function({bool accountId, bool importBatchId})
    >;
typedef $$SyncRunsTableCreateCompanionBuilder =
    SyncRunsCompanion Function({
      required String id,
      required String accountId,
      required String source,
      required String trigger,
      required String state,
      Value<String?> resultCode,
      required int startedAt,
      Value<int?> finishedAt,
      Value<String?> importBatchId,
      Value<int> rowid,
    });
typedef $$SyncRunsTableUpdateCompanionBuilder =
    SyncRunsCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> source,
      Value<String> trigger,
      Value<String> state,
      Value<String?> resultCode,
      Value<int> startedAt,
      Value<int?> finishedAt,
      Value<String?> importBatchId,
      Value<int> rowid,
    });

final class $$SyncRunsTableReferences
    extends BaseReferences<_$AppDatabase, $SyncRunsTable, SyncRun> {
  $$SyncRunsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) =>
      db.localAccounts.createAlias('sync_runs__account_id__local_accounts__id');

  $$LocalAccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$LocalAccountsTableTableManager(
      $_db,
      $_db.localAccounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $ImportBatchesTable _importBatchIdTable(_$AppDatabase db) => db
      .importBatches
      .createAlias('sync_runs__import_batch_id__import_batches__id');

  $$ImportBatchesTableProcessedTableManager? get importBatchId {
    final $_column = $_itemColumn<String>('import_batch_id');
    if ($_column == null) return null;
    final manager = $$ImportBatchesTableTableManager(
      $_db,
      $_db.importBatches,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_importBatchIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SyncRunsTableFilterComposer
    extends Composer<_$AppDatabase, $SyncRunsTable> {
  $$SyncRunsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get trigger => $composableBuilder(
    column: $table.trigger,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resultCode => $composableBuilder(
    column: $table.resultCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalAccountsTableFilterComposer get accountId {
    final $$LocalAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableFilterComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ImportBatchesTableFilterComposer get importBatchId {
    final $$ImportBatchesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.importBatchId,
      referencedTable: $db.importBatches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ImportBatchesTableFilterComposer(
            $db: $db,
            $table: $db.importBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncRunsTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncRunsTable> {
  $$SyncRunsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get trigger => $composableBuilder(
    column: $table.trigger,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resultCode => $composableBuilder(
    column: $table.resultCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalAccountsTableOrderingComposer get accountId {
    final $$LocalAccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableOrderingComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ImportBatchesTableOrderingComposer get importBatchId {
    final $$ImportBatchesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.importBatchId,
      referencedTable: $db.importBatches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ImportBatchesTableOrderingComposer(
            $db: $db,
            $table: $db.importBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncRunsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncRunsTable> {
  $$SyncRunsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get trigger =>
      $composableBuilder(column: $table.trigger, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get resultCode => $composableBuilder(
    column: $table.resultCode,
    builder: (column) => column,
  );

  GeneratedColumn<int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => column,
  );

  $$LocalAccountsTableAnnotationComposer get accountId {
    final $$LocalAccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ImportBatchesTableAnnotationComposer get importBatchId {
    final $$ImportBatchesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.importBatchId,
      referencedTable: $db.importBatches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ImportBatchesTableAnnotationComposer(
            $db: $db,
            $table: $db.importBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncRunsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncRunsTable,
          SyncRun,
          $$SyncRunsTableFilterComposer,
          $$SyncRunsTableOrderingComposer,
          $$SyncRunsTableAnnotationComposer,
          $$SyncRunsTableCreateCompanionBuilder,
          $$SyncRunsTableUpdateCompanionBuilder,
          (SyncRun, $$SyncRunsTableReferences),
          SyncRun,
          PrefetchHooks Function({bool accountId, bool importBatchId})
        > {
  $$SyncRunsTableTableManager(_$AppDatabase db, $SyncRunsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncRunsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncRunsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncRunsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> trigger = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> resultCode = const Value.absent(),
                Value<int> startedAt = const Value.absent(),
                Value<int?> finishedAt = const Value.absent(),
                Value<String?> importBatchId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncRunsCompanion(
                id: id,
                accountId: accountId,
                source: source,
                trigger: trigger,
                state: state,
                resultCode: resultCode,
                startedAt: startedAt,
                finishedAt: finishedAt,
                importBatchId: importBatchId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String source,
                required String trigger,
                required String state,
                Value<String?> resultCode = const Value.absent(),
                required int startedAt,
                Value<int?> finishedAt = const Value.absent(),
                Value<String?> importBatchId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncRunsCompanion.insert(
                id: id,
                accountId: accountId,
                source: source,
                trigger: trigger,
                state: state,
                resultCode: resultCode,
                startedAt: startedAt,
                finishedAt: finishedAt,
                importBatchId: importBatchId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SyncRunsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false, importBatchId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable: $$SyncRunsTableReferences
                                    ._accountIdTable(db),
                                referencedColumn: $$SyncRunsTableReferences
                                    ._accountIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (importBatchId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.importBatchId,
                                referencedTable: $$SyncRunsTableReferences
                                    ._importBatchIdTable(db),
                                referencedColumn: $$SyncRunsTableReferences
                                    ._importBatchIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$SyncRunsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncRunsTable,
      SyncRun,
      $$SyncRunsTableFilterComposer,
      $$SyncRunsTableOrderingComposer,
      $$SyncRunsTableAnnotationComposer,
      $$SyncRunsTableCreateCompanionBuilder,
      $$SyncRunsTableUpdateCompanionBuilder,
      (SyncRun, $$SyncRunsTableReferences),
      SyncRun,
      PrefetchHooks Function({bool accountId, bool importBatchId})
    >;
typedef $$ActionLogsTableCreateCompanionBuilder =
    ActionLogsCompanion Function({
      required String id,
      Value<String?> accountId,
      required String source,
      required String actionType,
      required String result,
      required String safeSummary,
      required int occurredAt,
      Value<int> rowid,
    });
typedef $$ActionLogsTableUpdateCompanionBuilder =
    ActionLogsCompanion Function({
      Value<String> id,
      Value<String?> accountId,
      Value<String> source,
      Value<String> actionType,
      Value<String> result,
      Value<String> safeSummary,
      Value<int> occurredAt,
      Value<int> rowid,
    });

final class $$ActionLogsTableReferences
    extends BaseReferences<_$AppDatabase, $ActionLogsTable, ActionLog> {
  $$ActionLogsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('action_logs__account_id__local_accounts__id');

  $$LocalAccountsTableProcessedTableManager? get accountId {
    final $_column = $_itemColumn<String>('account_id');
    if ($_column == null) return null;
    final manager = $$LocalAccountsTableTableManager(
      $_db,
      $_db.localAccounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ActionLogsTableFilterComposer
    extends Composer<_$AppDatabase, $ActionLogsTable> {
  $$ActionLogsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get result => $composableBuilder(
    column: $table.result,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get safeSummary => $composableBuilder(
    column: $table.safeSummary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalAccountsTableFilterComposer get accountId {
    final $$LocalAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableFilterComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ActionLogsTableOrderingComposer
    extends Composer<_$AppDatabase, $ActionLogsTable> {
  $$ActionLogsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get result => $composableBuilder(
    column: $table.result,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get safeSummary => $composableBuilder(
    column: $table.safeSummary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalAccountsTableOrderingComposer get accountId {
    final $$LocalAccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableOrderingComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ActionLogsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ActionLogsTable> {
  $$ActionLogsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get result =>
      $composableBuilder(column: $table.result, builder: (column) => column);

  GeneratedColumn<String> get safeSummary => $composableBuilder(
    column: $table.safeSummary,
    builder: (column) => column,
  );

  GeneratedColumn<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => column,
  );

  $$LocalAccountsTableAnnotationComposer get accountId {
    final $$LocalAccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ActionLogsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ActionLogsTable,
          ActionLog,
          $$ActionLogsTableFilterComposer,
          $$ActionLogsTableOrderingComposer,
          $$ActionLogsTableAnnotationComposer,
          $$ActionLogsTableCreateCompanionBuilder,
          $$ActionLogsTableUpdateCompanionBuilder,
          (ActionLog, $$ActionLogsTableReferences),
          ActionLog,
          PrefetchHooks Function({bool accountId})
        > {
  $$ActionLogsTableTableManager(_$AppDatabase db, $ActionLogsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ActionLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ActionLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ActionLogsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> accountId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> actionType = const Value.absent(),
                Value<String> result = const Value.absent(),
                Value<String> safeSummary = const Value.absent(),
                Value<int> occurredAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ActionLogsCompanion(
                id: id,
                accountId: accountId,
                source: source,
                actionType: actionType,
                result: result,
                safeSummary: safeSummary,
                occurredAt: occurredAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> accountId = const Value.absent(),
                required String source,
                required String actionType,
                required String result,
                required String safeSummary,
                required int occurredAt,
                Value<int> rowid = const Value.absent(),
              }) => ActionLogsCompanion.insert(
                id: id,
                accountId: accountId,
                source: source,
                actionType: actionType,
                result: result,
                safeSummary: safeSummary,
                occurredAt: occurredAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ActionLogsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable: $$ActionLogsTableReferences
                                    ._accountIdTable(db),
                                referencedColumn: $$ActionLogsTableReferences
                                    ._accountIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ActionLogsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ActionLogsTable,
      ActionLog,
      $$ActionLogsTableFilterComposer,
      $$ActionLogsTableOrderingComposer,
      $$ActionLogsTableAnnotationComposer,
      $$ActionLogsTableCreateCompanionBuilder,
      $$ActionLogsTableUpdateCompanionBuilder,
      (ActionLog, $$ActionLogsTableReferences),
      ActionLog,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$AgentPermissionPoliciesTableCreateCompanionBuilder =
    AgentPermissionPoliciesCompanion Function({
      required String id,
      required String accountId,
      required String actionType,
      required String policy,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$AgentPermissionPoliciesTableUpdateCompanionBuilder =
    AgentPermissionPoliciesCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> actionType,
      Value<String> policy,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$AgentPermissionPoliciesTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $AgentPermissionPoliciesTable,
          AgentPermissionPolicy
        > {
  $$AgentPermissionPoliciesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('agent_permission_policies__account_id__local_accounts__id');

  $$LocalAccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$LocalAccountsTableTableManager(
      $_db,
      $_db.localAccounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$AgentPermissionPoliciesTableFilterComposer
    extends Composer<_$AppDatabase, $AgentPermissionPoliciesTable> {
  $$AgentPermissionPoliciesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get policy => $composableBuilder(
    column: $table.policy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalAccountsTableFilterComposer get accountId {
    final $$LocalAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableFilterComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AgentPermissionPoliciesTableOrderingComposer
    extends Composer<_$AppDatabase, $AgentPermissionPoliciesTable> {
  $$AgentPermissionPoliciesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get policy => $composableBuilder(
    column: $table.policy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalAccountsTableOrderingComposer get accountId {
    final $$LocalAccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableOrderingComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AgentPermissionPoliciesTableAnnotationComposer
    extends Composer<_$AppDatabase, $AgentPermissionPoliciesTable> {
  $$AgentPermissionPoliciesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get policy =>
      $composableBuilder(column: $table.policy, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$LocalAccountsTableAnnotationComposer get accountId {
    final $$LocalAccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.localAccounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.localAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AgentPermissionPoliciesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AgentPermissionPoliciesTable,
          AgentPermissionPolicy,
          $$AgentPermissionPoliciesTableFilterComposer,
          $$AgentPermissionPoliciesTableOrderingComposer,
          $$AgentPermissionPoliciesTableAnnotationComposer,
          $$AgentPermissionPoliciesTableCreateCompanionBuilder,
          $$AgentPermissionPoliciesTableUpdateCompanionBuilder,
          (AgentPermissionPolicy, $$AgentPermissionPoliciesTableReferences),
          AgentPermissionPolicy,
          PrefetchHooks Function({bool accountId})
        > {
  $$AgentPermissionPoliciesTableTableManager(
    _$AppDatabase db,
    $AgentPermissionPoliciesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AgentPermissionPoliciesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$AgentPermissionPoliciesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$AgentPermissionPoliciesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> actionType = const Value.absent(),
                Value<String> policy = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AgentPermissionPoliciesCompanion(
                id: id,
                accountId: accountId,
                actionType: actionType,
                policy: policy,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String actionType,
                required String policy,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => AgentPermissionPoliciesCompanion.insert(
                id: id,
                accountId: accountId,
                actionType: actionType,
                policy: policy,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$AgentPermissionPoliciesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable:
                                    $$AgentPermissionPoliciesTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$AgentPermissionPoliciesTableReferences
                                        ._accountIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$AgentPermissionPoliciesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AgentPermissionPoliciesTable,
      AgentPermissionPolicy,
      $$AgentPermissionPoliciesTableFilterComposer,
      $$AgentPermissionPoliciesTableOrderingComposer,
      $$AgentPermissionPoliciesTableAnnotationComposer,
      $$AgentPermissionPoliciesTableCreateCompanionBuilder,
      $$AgentPermissionPoliciesTableUpdateCompanionBuilder,
      (AgentPermissionPolicy, $$AgentPermissionPoliciesTableReferences),
      AgentPermissionPolicy,
      PrefetchHooks Function({bool accountId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$LocalAccountsTableTableManager get localAccounts =>
      $$LocalAccountsTableTableManager(_db, _db.localAccounts);
  $$CredentialAccountsTableTableManager get credentialAccounts =>
      $$CredentialAccountsTableTableManager(_db, _db.credentialAccounts);
  $$SourceConfigsTableTableManager get sourceConfigs =>
      $$SourceConfigsTableTableManager(_db, _db.sourceConfigs);
  $$ImportBatchesTableTableManager get importBatches =>
      $$ImportBatchesTableTableManager(_db, _db.importBatches);
  $$SourceRecordsTableTableManager get sourceRecords =>
      $$SourceRecordsTableTableManager(_db, _db.sourceRecords);
  $$SyncRunsTableTableManager get syncRuns =>
      $$SyncRunsTableTableManager(_db, _db.syncRuns);
  $$ActionLogsTableTableManager get actionLogs =>
      $$ActionLogsTableTableManager(_db, _db.actionLogs);
  $$AgentPermissionPoliciesTableTableManager get agentPermissionPolicies =>
      $$AgentPermissionPoliciesTableTableManager(
        _db,
        _db.agentPermissionPolicies,
      );
}
