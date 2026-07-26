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
    with TableInfo<$ImportBatchesTable, ImportBatch> {
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
    Insertable<ImportBatch> instance, {
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
  ImportBatch map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ImportBatch(
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

class ImportBatch extends DataClass implements Insertable<ImportBatch> {
  final String id;
  final String accountId;
  final String bundleId;
  final String digest;
  final String source;
  final String scopeKey;
  final int importedAt;
  final String origin;
  const ImportBatch({
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

  factory ImportBatch.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ImportBatch(
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

  ImportBatch copyWith({
    String? id,
    String? accountId,
    String? bundleId,
    String? digest,
    String? source,
    String? scopeKey,
    int? importedAt,
    String? origin,
  }) => ImportBatch(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    bundleId: bundleId ?? this.bundleId,
    digest: digest ?? this.digest,
    source: source ?? this.source,
    scopeKey: scopeKey ?? this.scopeKey,
    importedAt: importedAt ?? this.importedAt,
    origin: origin ?? this.origin,
  );
  ImportBatch copyWithCompanion(ImportBatchesCompanion data) {
    return ImportBatch(
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
    return (StringBuffer('ImportBatch(')
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
      (other is ImportBatch &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.bundleId == this.bundleId &&
          other.digest == this.digest &&
          other.source == this.source &&
          other.scopeKey == this.scopeKey &&
          other.importedAt == this.importedAt &&
          other.origin == this.origin);
}

class ImportBatchesCompanion extends UpdateCompanion<ImportBatch> {
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
  static Insertable<ImportBatch> custom({
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

class $CourseSeriesTable extends CourseSeries
    with TableInfo<$CourseSeriesTable, CourseSery> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CourseSeriesTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _courseCodeMeta = const VerificationMeta(
    'courseCode',
  );
  @override
  late final GeneratedColumn<String> courseCode = GeneratedColumn<String>(
    'course_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _semesterKeyMeta = const VerificationMeta(
    'semesterKey',
  );
  @override
  late final GeneratedColumn<String> semesterKey = GeneratedColumn<String>(
    'semester_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _participantsJsonMeta = const VerificationMeta(
    'participantsJson',
  );
  @override
  late final GeneratedColumn<String> participantsJson = GeneratedColumn<String>(
    'participants_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _sourceDetailsJsonMeta = const VerificationMeta(
    'sourceDetailsJson',
  );
  @override
  late final GeneratedColumn<String> sourceDetailsJson =
      GeneratedColumn<String>(
        'source_details_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
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
    accountId,
    source,
    externalId,
    title,
    courseCode,
    semesterKey,
    participantsJson,
    sourceDetailsJson,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'course_series';
  @override
  VerificationContext validateIntegrity(
    Insertable<CourseSery> instance, {
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
    if (data.containsKey('external_id')) {
      context.handle(
        _externalIdMeta,
        externalId.isAcceptableOrUnknown(data['external_id']!, _externalIdMeta),
      );
    } else if (isInserting) {
      context.missing(_externalIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('course_code')) {
      context.handle(
        _courseCodeMeta,
        courseCode.isAcceptableOrUnknown(data['course_code']!, _courseCodeMeta),
      );
    }
    if (data.containsKey('semester_key')) {
      context.handle(
        _semesterKeyMeta,
        semesterKey.isAcceptableOrUnknown(
          data['semester_key']!,
          _semesterKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_semesterKeyMeta);
    }
    if (data.containsKey('participants_json')) {
      context.handle(
        _participantsJsonMeta,
        participantsJson.isAcceptableOrUnknown(
          data['participants_json']!,
          _participantsJsonMeta,
        ),
      );
    }
    if (data.containsKey('source_details_json')) {
      context.handle(
        _sourceDetailsJsonMeta,
        sourceDetailsJson.isAcceptableOrUnknown(
          data['source_details_json']!,
          _sourceDetailsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceDetailsJsonMeta);
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
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, source, externalId},
  ];
  @override
  CourseSery map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CourseSery(
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
      externalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}external_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      courseCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}course_code'],
      ),
      semesterKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}semester_key'],
      )!,
      participantsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}participants_json'],
      )!,
      sourceDetailsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_details_json'],
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
  $CourseSeriesTable createAlias(String alias) {
    return $CourseSeriesTable(attachedDatabase, alias);
  }
}

class CourseSery extends DataClass implements Insertable<CourseSery> {
  final String id;
  final String accountId;
  final String source;
  final String externalId;
  final String title;
  final String? courseCode;
  final String semesterKey;
  final String participantsJson;
  final String sourceDetailsJson;
  final int createdAt;
  final int updatedAt;
  const CourseSery({
    required this.id,
    required this.accountId,
    required this.source,
    required this.externalId,
    required this.title,
    this.courseCode,
    required this.semesterKey,
    required this.participantsJson,
    required this.sourceDetailsJson,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['source'] = Variable<String>(source);
    map['external_id'] = Variable<String>(externalId);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || courseCode != null) {
      map['course_code'] = Variable<String>(courseCode);
    }
    map['semester_key'] = Variable<String>(semesterKey);
    map['participants_json'] = Variable<String>(participantsJson);
    map['source_details_json'] = Variable<String>(sourceDetailsJson);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  CourseSeriesCompanion toCompanion(bool nullToAbsent) {
    return CourseSeriesCompanion(
      id: Value(id),
      accountId: Value(accountId),
      source: Value(source),
      externalId: Value(externalId),
      title: Value(title),
      courseCode: courseCode == null && nullToAbsent
          ? const Value.absent()
          : Value(courseCode),
      semesterKey: Value(semesterKey),
      participantsJson: Value(participantsJson),
      sourceDetailsJson: Value(sourceDetailsJson),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory CourseSery.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CourseSery(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      source: serializer.fromJson<String>(json['source']),
      externalId: serializer.fromJson<String>(json['externalId']),
      title: serializer.fromJson<String>(json['title']),
      courseCode: serializer.fromJson<String?>(json['courseCode']),
      semesterKey: serializer.fromJson<String>(json['semesterKey']),
      participantsJson: serializer.fromJson<String>(json['participantsJson']),
      sourceDetailsJson: serializer.fromJson<String>(json['sourceDetailsJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
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
      'externalId': serializer.toJson<String>(externalId),
      'title': serializer.toJson<String>(title),
      'courseCode': serializer.toJson<String?>(courseCode),
      'semesterKey': serializer.toJson<String>(semesterKey),
      'participantsJson': serializer.toJson<String>(participantsJson),
      'sourceDetailsJson': serializer.toJson<String>(sourceDetailsJson),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  CourseSery copyWith({
    String? id,
    String? accountId,
    String? source,
    String? externalId,
    String? title,
    Value<String?> courseCode = const Value.absent(),
    String? semesterKey,
    String? participantsJson,
    String? sourceDetailsJson,
    int? createdAt,
    int? updatedAt,
  }) => CourseSery(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    source: source ?? this.source,
    externalId: externalId ?? this.externalId,
    title: title ?? this.title,
    courseCode: courseCode.present ? courseCode.value : this.courseCode,
    semesterKey: semesterKey ?? this.semesterKey,
    participantsJson: participantsJson ?? this.participantsJson,
    sourceDetailsJson: sourceDetailsJson ?? this.sourceDetailsJson,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  CourseSery copyWithCompanion(CourseSeriesCompanion data) {
    return CourseSery(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      source: data.source.present ? data.source.value : this.source,
      externalId: data.externalId.present
          ? data.externalId.value
          : this.externalId,
      title: data.title.present ? data.title.value : this.title,
      courseCode: data.courseCode.present
          ? data.courseCode.value
          : this.courseCode,
      semesterKey: data.semesterKey.present
          ? data.semesterKey.value
          : this.semesterKey,
      participantsJson: data.participantsJson.present
          ? data.participantsJson.value
          : this.participantsJson,
      sourceDetailsJson: data.sourceDetailsJson.present
          ? data.sourceDetailsJson.value
          : this.sourceDetailsJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CourseSery(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('externalId: $externalId, ')
          ..write('title: $title, ')
          ..write('courseCode: $courseCode, ')
          ..write('semesterKey: $semesterKey, ')
          ..write('participantsJson: $participantsJson, ')
          ..write('sourceDetailsJson: $sourceDetailsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    source,
    externalId,
    title,
    courseCode,
    semesterKey,
    participantsJson,
    sourceDetailsJson,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CourseSery &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.source == this.source &&
          other.externalId == this.externalId &&
          other.title == this.title &&
          other.courseCode == this.courseCode &&
          other.semesterKey == this.semesterKey &&
          other.participantsJson == this.participantsJson &&
          other.sourceDetailsJson == this.sourceDetailsJson &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class CourseSeriesCompanion extends UpdateCompanion<CourseSery> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> source;
  final Value<String> externalId;
  final Value<String> title;
  final Value<String?> courseCode;
  final Value<String> semesterKey;
  final Value<String> participantsJson;
  final Value<String> sourceDetailsJson;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const CourseSeriesCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.source = const Value.absent(),
    this.externalId = const Value.absent(),
    this.title = const Value.absent(),
    this.courseCode = const Value.absent(),
    this.semesterKey = const Value.absent(),
    this.participantsJson = const Value.absent(),
    this.sourceDetailsJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CourseSeriesCompanion.insert({
    required String id,
    required String accountId,
    required String source,
    required String externalId,
    required String title,
    this.courseCode = const Value.absent(),
    required String semesterKey,
    this.participantsJson = const Value.absent(),
    required String sourceDetailsJson,
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       source = Value(source),
       externalId = Value(externalId),
       title = Value(title),
       semesterKey = Value(semesterKey),
       sourceDetailsJson = Value(sourceDetailsJson),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<CourseSery> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? source,
    Expression<String>? externalId,
    Expression<String>? title,
    Expression<String>? courseCode,
    Expression<String>? semesterKey,
    Expression<String>? participantsJson,
    Expression<String>? sourceDetailsJson,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (source != null) 'source': source,
      if (externalId != null) 'external_id': externalId,
      if (title != null) 'title': title,
      if (courseCode != null) 'course_code': courseCode,
      if (semesterKey != null) 'semester_key': semesterKey,
      if (participantsJson != null) 'participants_json': participantsJson,
      if (sourceDetailsJson != null) 'source_details_json': sourceDetailsJson,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CourseSeriesCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? source,
    Value<String>? externalId,
    Value<String>? title,
    Value<String?>? courseCode,
    Value<String>? semesterKey,
    Value<String>? participantsJson,
    Value<String>? sourceDetailsJson,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return CourseSeriesCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      source: source ?? this.source,
      externalId: externalId ?? this.externalId,
      title: title ?? this.title,
      courseCode: courseCode ?? this.courseCode,
      semesterKey: semesterKey ?? this.semesterKey,
      participantsJson: participantsJson ?? this.participantsJson,
      sourceDetailsJson: sourceDetailsJson ?? this.sourceDetailsJson,
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
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (externalId.present) {
      map['external_id'] = Variable<String>(externalId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (courseCode.present) {
      map['course_code'] = Variable<String>(courseCode.value);
    }
    if (semesterKey.present) {
      map['semester_key'] = Variable<String>(semesterKey.value);
    }
    if (participantsJson.present) {
      map['participants_json'] = Variable<String>(participantsJson.value);
    }
    if (sourceDetailsJson.present) {
      map['source_details_json'] = Variable<String>(sourceDetailsJson.value);
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
    return (StringBuffer('CourseSeriesCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('externalId: $externalId, ')
          ..write('title: $title, ')
          ..write('courseCode: $courseCode, ')
          ..write('semesterKey: $semesterKey, ')
          ..write('participantsJson: $participantsJson, ')
          ..write('sourceDetailsJson: $sourceDetailsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CalendarEventSeriesTable extends CalendarEventSeries
    with TableInfo<$CalendarEventSeriesTable, CalendarEventSery> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalendarEventSeriesTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _eventTypeMeta = const VerificationMeta(
    'eventType',
  );
  @override
  late final GeneratedColumn<String> eventType = GeneratedColumn<String>(
    'event_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timezoneMeta = const VerificationMeta(
    'timezone',
  );
  @override
  late final GeneratedColumn<String> timezone = GeneratedColumn<String>(
    'timezone',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startAtMeta = const VerificationMeta(
    'startAt',
  );
  @override
  late final GeneratedColumn<int> startAt = GeneratedColumn<int>(
    'start_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationMinutesMeta = const VerificationMeta(
    'durationMinutes',
  );
  @override
  late final GeneratedColumn<int> durationMinutes = GeneratedColumn<int>(
    'duration_minutes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recurrenceJsonMeta = const VerificationMeta(
    'recurrenceJson',
  );
  @override
  late final GeneratedColumn<String> recurrenceJson = GeneratedColumn<String>(
    'recurrence_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _effectiveFromMeta = const VerificationMeta(
    'effectiveFrom',
  );
  @override
  late final GeneratedColumn<String> effectiveFrom = GeneratedColumn<String>(
    'effective_from',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _effectiveThroughMeta = const VerificationMeta(
    'effectiveThrough',
  );
  @override
  late final GeneratedColumn<String> effectiveThrough = GeneratedColumn<String>(
    'effective_through',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _locationNameMeta = const VerificationMeta(
    'locationName',
  );
  @override
  late final GeneratedColumn<String> locationName = GeneratedColumn<String>(
    'location_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _completionPolicyMeta = const VerificationMeta(
    'completionPolicy',
  );
  @override
  late final GeneratedColumn<String> completionPolicy = GeneratedColumn<String>(
    'completion_policy',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('auto_complete'),
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
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
    accountId,
    title,
    description,
    eventType,
    timezone,
    startAt,
    durationMinutes,
    recurrenceJson,
    effectiveFrom,
    effectiveThrough,
    locationName,
    completionPolicy,
    deleted,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calendar_event_series';
  @override
  VerificationContext validateIntegrity(
    Insertable<CalendarEventSery> instance, {
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
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('event_type')) {
      context.handle(
        _eventTypeMeta,
        eventType.isAcceptableOrUnknown(data['event_type']!, _eventTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_eventTypeMeta);
    }
    if (data.containsKey('timezone')) {
      context.handle(
        _timezoneMeta,
        timezone.isAcceptableOrUnknown(data['timezone']!, _timezoneMeta),
      );
    } else if (isInserting) {
      context.missing(_timezoneMeta);
    }
    if (data.containsKey('start_at')) {
      context.handle(
        _startAtMeta,
        startAt.isAcceptableOrUnknown(data['start_at']!, _startAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startAtMeta);
    }
    if (data.containsKey('duration_minutes')) {
      context.handle(
        _durationMinutesMeta,
        durationMinutes.isAcceptableOrUnknown(
          data['duration_minutes']!,
          _durationMinutesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_durationMinutesMeta);
    }
    if (data.containsKey('recurrence_json')) {
      context.handle(
        _recurrenceJsonMeta,
        recurrenceJson.isAcceptableOrUnknown(
          data['recurrence_json']!,
          _recurrenceJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_recurrenceJsonMeta);
    }
    if (data.containsKey('effective_from')) {
      context.handle(
        _effectiveFromMeta,
        effectiveFrom.isAcceptableOrUnknown(
          data['effective_from']!,
          _effectiveFromMeta,
        ),
      );
    }
    if (data.containsKey('effective_through')) {
      context.handle(
        _effectiveThroughMeta,
        effectiveThrough.isAcceptableOrUnknown(
          data['effective_through']!,
          _effectiveThroughMeta,
        ),
      );
    }
    if (data.containsKey('location_name')) {
      context.handle(
        _locationNameMeta,
        locationName.isAcceptableOrUnknown(
          data['location_name']!,
          _locationNameMeta,
        ),
      );
    }
    if (data.containsKey('completion_policy')) {
      context.handle(
        _completionPolicyMeta,
        completionPolicy.isAcceptableOrUnknown(
          data['completion_policy']!,
          _completionPolicyMeta,
        ),
      );
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
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
  CalendarEventSery map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalendarEventSery(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      ),
      eventType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_type'],
      )!,
      timezone: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}timezone'],
      )!,
      startAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_at'],
      )!,
      durationMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_minutes'],
      )!,
      recurrenceJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recurrence_json'],
      )!,
      effectiveFrom: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}effective_from'],
      ),
      effectiveThrough: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}effective_through'],
      ),
      locationName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location_name'],
      ),
      completionPolicy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}completion_policy'],
      )!,
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
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
  $CalendarEventSeriesTable createAlias(String alias) {
    return $CalendarEventSeriesTable(attachedDatabase, alias);
  }
}

class CalendarEventSery extends DataClass
    implements Insertable<CalendarEventSery> {
  final String id;
  final String accountId;
  final String title;
  final String? description;
  final String eventType;
  final String timezone;
  final int startAt;
  final int durationMinutes;
  final String recurrenceJson;
  final String? effectiveFrom;
  final String? effectiveThrough;
  final String? locationName;
  final String completionPolicy;
  final bool deleted;
  final int createdAt;
  final int updatedAt;
  const CalendarEventSery({
    required this.id,
    required this.accountId,
    required this.title,
    this.description,
    required this.eventType,
    required this.timezone,
    required this.startAt,
    required this.durationMinutes,
    required this.recurrenceJson,
    this.effectiveFrom,
    this.effectiveThrough,
    this.locationName,
    required this.completionPolicy,
    required this.deleted,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || description != null) {
      map['description'] = Variable<String>(description);
    }
    map['event_type'] = Variable<String>(eventType);
    map['timezone'] = Variable<String>(timezone);
    map['start_at'] = Variable<int>(startAt);
    map['duration_minutes'] = Variable<int>(durationMinutes);
    map['recurrence_json'] = Variable<String>(recurrenceJson);
    if (!nullToAbsent || effectiveFrom != null) {
      map['effective_from'] = Variable<String>(effectiveFrom);
    }
    if (!nullToAbsent || effectiveThrough != null) {
      map['effective_through'] = Variable<String>(effectiveThrough);
    }
    if (!nullToAbsent || locationName != null) {
      map['location_name'] = Variable<String>(locationName);
    }
    map['completion_policy'] = Variable<String>(completionPolicy);
    map['deleted'] = Variable<bool>(deleted);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  CalendarEventSeriesCompanion toCompanion(bool nullToAbsent) {
    return CalendarEventSeriesCompanion(
      id: Value(id),
      accountId: Value(accountId),
      title: Value(title),
      description: description == null && nullToAbsent
          ? const Value.absent()
          : Value(description),
      eventType: Value(eventType),
      timezone: Value(timezone),
      startAt: Value(startAt),
      durationMinutes: Value(durationMinutes),
      recurrenceJson: Value(recurrenceJson),
      effectiveFrom: effectiveFrom == null && nullToAbsent
          ? const Value.absent()
          : Value(effectiveFrom),
      effectiveThrough: effectiveThrough == null && nullToAbsent
          ? const Value.absent()
          : Value(effectiveThrough),
      locationName: locationName == null && nullToAbsent
          ? const Value.absent()
          : Value(locationName),
      completionPolicy: Value(completionPolicy),
      deleted: Value(deleted),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory CalendarEventSery.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalendarEventSery(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      title: serializer.fromJson<String>(json['title']),
      description: serializer.fromJson<String?>(json['description']),
      eventType: serializer.fromJson<String>(json['eventType']),
      timezone: serializer.fromJson<String>(json['timezone']),
      startAt: serializer.fromJson<int>(json['startAt']),
      durationMinutes: serializer.fromJson<int>(json['durationMinutes']),
      recurrenceJson: serializer.fromJson<String>(json['recurrenceJson']),
      effectiveFrom: serializer.fromJson<String?>(json['effectiveFrom']),
      effectiveThrough: serializer.fromJson<String?>(json['effectiveThrough']),
      locationName: serializer.fromJson<String?>(json['locationName']),
      completionPolicy: serializer.fromJson<String>(json['completionPolicy']),
      deleted: serializer.fromJson<bool>(json['deleted']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'title': serializer.toJson<String>(title),
      'description': serializer.toJson<String?>(description),
      'eventType': serializer.toJson<String>(eventType),
      'timezone': serializer.toJson<String>(timezone),
      'startAt': serializer.toJson<int>(startAt),
      'durationMinutes': serializer.toJson<int>(durationMinutes),
      'recurrenceJson': serializer.toJson<String>(recurrenceJson),
      'effectiveFrom': serializer.toJson<String?>(effectiveFrom),
      'effectiveThrough': serializer.toJson<String?>(effectiveThrough),
      'locationName': serializer.toJson<String?>(locationName),
      'completionPolicy': serializer.toJson<String>(completionPolicy),
      'deleted': serializer.toJson<bool>(deleted),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  CalendarEventSery copyWith({
    String? id,
    String? accountId,
    String? title,
    Value<String?> description = const Value.absent(),
    String? eventType,
    String? timezone,
    int? startAt,
    int? durationMinutes,
    String? recurrenceJson,
    Value<String?> effectiveFrom = const Value.absent(),
    Value<String?> effectiveThrough = const Value.absent(),
    Value<String?> locationName = const Value.absent(),
    String? completionPolicy,
    bool? deleted,
    int? createdAt,
    int? updatedAt,
  }) => CalendarEventSery(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    title: title ?? this.title,
    description: description.present ? description.value : this.description,
    eventType: eventType ?? this.eventType,
    timezone: timezone ?? this.timezone,
    startAt: startAt ?? this.startAt,
    durationMinutes: durationMinutes ?? this.durationMinutes,
    recurrenceJson: recurrenceJson ?? this.recurrenceJson,
    effectiveFrom: effectiveFrom.present
        ? effectiveFrom.value
        : this.effectiveFrom,
    effectiveThrough: effectiveThrough.present
        ? effectiveThrough.value
        : this.effectiveThrough,
    locationName: locationName.present ? locationName.value : this.locationName,
    completionPolicy: completionPolicy ?? this.completionPolicy,
    deleted: deleted ?? this.deleted,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  CalendarEventSery copyWithCompanion(CalendarEventSeriesCompanion data) {
    return CalendarEventSery(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      title: data.title.present ? data.title.value : this.title,
      description: data.description.present
          ? data.description.value
          : this.description,
      eventType: data.eventType.present ? data.eventType.value : this.eventType,
      timezone: data.timezone.present ? data.timezone.value : this.timezone,
      startAt: data.startAt.present ? data.startAt.value : this.startAt,
      durationMinutes: data.durationMinutes.present
          ? data.durationMinutes.value
          : this.durationMinutes,
      recurrenceJson: data.recurrenceJson.present
          ? data.recurrenceJson.value
          : this.recurrenceJson,
      effectiveFrom: data.effectiveFrom.present
          ? data.effectiveFrom.value
          : this.effectiveFrom,
      effectiveThrough: data.effectiveThrough.present
          ? data.effectiveThrough.value
          : this.effectiveThrough,
      locationName: data.locationName.present
          ? data.locationName.value
          : this.locationName,
      completionPolicy: data.completionPolicy.present
          ? data.completionPolicy.value
          : this.completionPolicy,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalendarEventSery(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('title: $title, ')
          ..write('description: $description, ')
          ..write('eventType: $eventType, ')
          ..write('timezone: $timezone, ')
          ..write('startAt: $startAt, ')
          ..write('durationMinutes: $durationMinutes, ')
          ..write('recurrenceJson: $recurrenceJson, ')
          ..write('effectiveFrom: $effectiveFrom, ')
          ..write('effectiveThrough: $effectiveThrough, ')
          ..write('locationName: $locationName, ')
          ..write('completionPolicy: $completionPolicy, ')
          ..write('deleted: $deleted, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    title,
    description,
    eventType,
    timezone,
    startAt,
    durationMinutes,
    recurrenceJson,
    effectiveFrom,
    effectiveThrough,
    locationName,
    completionPolicy,
    deleted,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalendarEventSery &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.title == this.title &&
          other.description == this.description &&
          other.eventType == this.eventType &&
          other.timezone == this.timezone &&
          other.startAt == this.startAt &&
          other.durationMinutes == this.durationMinutes &&
          other.recurrenceJson == this.recurrenceJson &&
          other.effectiveFrom == this.effectiveFrom &&
          other.effectiveThrough == this.effectiveThrough &&
          other.locationName == this.locationName &&
          other.completionPolicy == this.completionPolicy &&
          other.deleted == this.deleted &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class CalendarEventSeriesCompanion extends UpdateCompanion<CalendarEventSery> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> title;
  final Value<String?> description;
  final Value<String> eventType;
  final Value<String> timezone;
  final Value<int> startAt;
  final Value<int> durationMinutes;
  final Value<String> recurrenceJson;
  final Value<String?> effectiveFrom;
  final Value<String?> effectiveThrough;
  final Value<String?> locationName;
  final Value<String> completionPolicy;
  final Value<bool> deleted;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const CalendarEventSeriesCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.title = const Value.absent(),
    this.description = const Value.absent(),
    this.eventType = const Value.absent(),
    this.timezone = const Value.absent(),
    this.startAt = const Value.absent(),
    this.durationMinutes = const Value.absent(),
    this.recurrenceJson = const Value.absent(),
    this.effectiveFrom = const Value.absent(),
    this.effectiveThrough = const Value.absent(),
    this.locationName = const Value.absent(),
    this.completionPolicy = const Value.absent(),
    this.deleted = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CalendarEventSeriesCompanion.insert({
    required String id,
    required String accountId,
    required String title,
    this.description = const Value.absent(),
    required String eventType,
    required String timezone,
    required int startAt,
    required int durationMinutes,
    required String recurrenceJson,
    this.effectiveFrom = const Value.absent(),
    this.effectiveThrough = const Value.absent(),
    this.locationName = const Value.absent(),
    this.completionPolicy = const Value.absent(),
    this.deleted = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       title = Value(title),
       eventType = Value(eventType),
       timezone = Value(timezone),
       startAt = Value(startAt),
       durationMinutes = Value(durationMinutes),
       recurrenceJson = Value(recurrenceJson),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<CalendarEventSery> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? title,
    Expression<String>? description,
    Expression<String>? eventType,
    Expression<String>? timezone,
    Expression<int>? startAt,
    Expression<int>? durationMinutes,
    Expression<String>? recurrenceJson,
    Expression<String>? effectiveFrom,
    Expression<String>? effectiveThrough,
    Expression<String>? locationName,
    Expression<String>? completionPolicy,
    Expression<bool>? deleted,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (eventType != null) 'event_type': eventType,
      if (timezone != null) 'timezone': timezone,
      if (startAt != null) 'start_at': startAt,
      if (durationMinutes != null) 'duration_minutes': durationMinutes,
      if (recurrenceJson != null) 'recurrence_json': recurrenceJson,
      if (effectiveFrom != null) 'effective_from': effectiveFrom,
      if (effectiveThrough != null) 'effective_through': effectiveThrough,
      if (locationName != null) 'location_name': locationName,
      if (completionPolicy != null) 'completion_policy': completionPolicy,
      if (deleted != null) 'deleted': deleted,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CalendarEventSeriesCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? title,
    Value<String?>? description,
    Value<String>? eventType,
    Value<String>? timezone,
    Value<int>? startAt,
    Value<int>? durationMinutes,
    Value<String>? recurrenceJson,
    Value<String?>? effectiveFrom,
    Value<String?>? effectiveThrough,
    Value<String?>? locationName,
    Value<String>? completionPolicy,
    Value<bool>? deleted,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return CalendarEventSeriesCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      title: title ?? this.title,
      description: description ?? this.description,
      eventType: eventType ?? this.eventType,
      timezone: timezone ?? this.timezone,
      startAt: startAt ?? this.startAt,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      recurrenceJson: recurrenceJson ?? this.recurrenceJson,
      effectiveFrom: effectiveFrom ?? this.effectiveFrom,
      effectiveThrough: effectiveThrough ?? this.effectiveThrough,
      locationName: locationName ?? this.locationName,
      completionPolicy: completionPolicy ?? this.completionPolicy,
      deleted: deleted ?? this.deleted,
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
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (eventType.present) {
      map['event_type'] = Variable<String>(eventType.value);
    }
    if (timezone.present) {
      map['timezone'] = Variable<String>(timezone.value);
    }
    if (startAt.present) {
      map['start_at'] = Variable<int>(startAt.value);
    }
    if (durationMinutes.present) {
      map['duration_minutes'] = Variable<int>(durationMinutes.value);
    }
    if (recurrenceJson.present) {
      map['recurrence_json'] = Variable<String>(recurrenceJson.value);
    }
    if (effectiveFrom.present) {
      map['effective_from'] = Variable<String>(effectiveFrom.value);
    }
    if (effectiveThrough.present) {
      map['effective_through'] = Variable<String>(effectiveThrough.value);
    }
    if (locationName.present) {
      map['location_name'] = Variable<String>(locationName.value);
    }
    if (completionPolicy.present) {
      map['completion_policy'] = Variable<String>(completionPolicy.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
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
    return (StringBuffer('CalendarEventSeriesCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('title: $title, ')
          ..write('description: $description, ')
          ..write('eventType: $eventType, ')
          ..write('timezone: $timezone, ')
          ..write('startAt: $startAt, ')
          ..write('durationMinutes: $durationMinutes, ')
          ..write('recurrenceJson: $recurrenceJson, ')
          ..write('effectiveFrom: $effectiveFrom, ')
          ..write('effectiveThrough: $effectiveThrough, ')
          ..write('locationName: $locationName, ')
          ..write('completionPolicy: $completionPolicy, ')
          ..write('deleted: $deleted, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CalendarEventsTable extends CalendarEvents
    with TableInfo<$CalendarEventsTable, CalendarEvent> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalendarEventsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _externalIdMeta = const VerificationMeta(
    'externalId',
  );
  @override
  late final GeneratedColumn<String> externalId = GeneratedColumn<String>(
    'external_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceSeriesExternalIdMeta =
      const VerificationMeta('sourceSeriesExternalId');
  @override
  late final GeneratedColumn<String> sourceSeriesExternalId =
      GeneratedColumn<String>(
        'source_series_external_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _personalSeriesIdMeta = const VerificationMeta(
    'personalSeriesId',
  );
  @override
  late final GeneratedColumn<String> personalSeriesId = GeneratedColumn<String>(
    'personal_series_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES calendar_event_series (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _occurrenceKeyMeta = const VerificationMeta(
    'occurrenceKey',
  );
  @override
  late final GeneratedColumn<String> occurrenceKey = GeneratedColumn<String>(
    'occurrence_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('active'),
  );
  static const VerificationMeta _startAtMeta = const VerificationMeta(
    'startAt',
  );
  @override
  late final GeneratedColumn<int> startAt = GeneratedColumn<int>(
    'start_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _endAtMeta = const VerificationMeta('endAt');
  @override
  late final GeneratedColumn<int> endAt = GeneratedColumn<int>(
    'end_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _allDayMeta = const VerificationMeta('allDay');
  @override
  late final GeneratedColumn<bool> allDay = GeneratedColumn<bool>(
    'all_day',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("all_day" IN (0, 1))',
    ),
  );
  static const VerificationMeta _startDateMeta = const VerificationMeta(
    'startDate',
  );
  @override
  late final GeneratedColumn<String> startDate = GeneratedColumn<String>(
    'start_date',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _endDateExclusiveMeta = const VerificationMeta(
    'endDateExclusive',
  );
  @override
  late final GeneratedColumn<String> endDateExclusive = GeneratedColumn<String>(
    'end_date_exclusive',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _timezoneMeta = const VerificationMeta(
    'timezone',
  );
  @override
  late final GeneratedColumn<String> timezone = GeneratedColumn<String>(
    'timezone',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _locationNameMeta = const VerificationMeta(
    'locationName',
  );
  @override
  late final GeneratedColumn<String> locationName = GeneratedColumn<String>(
    'location_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _buildingNameMeta = const VerificationMeta(
    'buildingName',
  );
  @override
  late final GeneratedColumn<String> buildingName = GeneratedColumn<String>(
    'building_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _campusNameMeta = const VerificationMeta(
    'campusName',
  );
  @override
  late final GeneratedColumn<String> campusName = GeneratedColumn<String>(
    'campus_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _participantsJsonMeta = const VerificationMeta(
    'participantsJson',
  );
  @override
  late final GeneratedColumn<String> participantsJson = GeneratedColumn<String>(
    'participants_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _sourceDetailsJsonMeta = const VerificationMeta(
    'sourceDetailsJson',
  );
  @override
  late final GeneratedColumn<String> sourceDetailsJson =
      GeneratedColumn<String>(
        'source_details_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('{}'),
      );
  static const VerificationMeta _importanceMeta = const VerificationMeta(
    'importance',
  );
  @override
  late final GeneratedColumn<String> importance = GeneratedColumn<String>(
    'importance',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('normal'),
  );
  static const VerificationMeta _completionPolicyMeta = const VerificationMeta(
    'completionPolicy',
  );
  @override
  late final GeneratedColumn<String> completionPolicy = GeneratedColumn<String>(
    'completion_policy',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('auto_complete'),
  );
  static const VerificationMeta _completedAtMeta = const VerificationMeta(
    'completedAt',
  );
  @override
  late final GeneratedColumn<int> completedAt = GeneratedColumn<int>(
    'completed_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<String> color = GeneratedColumn<String>(
    'color',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
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
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    source,
    externalId,
    sourceSeriesExternalId,
    personalSeriesId,
    occurrenceKey,
    title,
    description,
    type,
    status,
    startAt,
    endAt,
    allDay,
    startDate,
    endDateExclusive,
    timezone,
    locationName,
    buildingName,
    campusName,
    participantsJson,
    sourceDetailsJson,
    importance,
    completionPolicy,
    completedAt,
    color,
    tagsJson,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calendar_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<CalendarEvent> instance, {
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
    if (data.containsKey('external_id')) {
      context.handle(
        _externalIdMeta,
        externalId.isAcceptableOrUnknown(data['external_id']!, _externalIdMeta),
      );
    }
    if (data.containsKey('source_series_external_id')) {
      context.handle(
        _sourceSeriesExternalIdMeta,
        sourceSeriesExternalId.isAcceptableOrUnknown(
          data['source_series_external_id']!,
          _sourceSeriesExternalIdMeta,
        ),
      );
    }
    if (data.containsKey('personal_series_id')) {
      context.handle(
        _personalSeriesIdMeta,
        personalSeriesId.isAcceptableOrUnknown(
          data['personal_series_id']!,
          _personalSeriesIdMeta,
        ),
      );
    }
    if (data.containsKey('occurrence_key')) {
      context.handle(
        _occurrenceKeyMeta,
        occurrenceKey.isAcceptableOrUnknown(
          data['occurrence_key']!,
          _occurrenceKeyMeta,
        ),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('start_at')) {
      context.handle(
        _startAtMeta,
        startAt.isAcceptableOrUnknown(data['start_at']!, _startAtMeta),
      );
    }
    if (data.containsKey('end_at')) {
      context.handle(
        _endAtMeta,
        endAt.isAcceptableOrUnknown(data['end_at']!, _endAtMeta),
      );
    }
    if (data.containsKey('all_day')) {
      context.handle(
        _allDayMeta,
        allDay.isAcceptableOrUnknown(data['all_day']!, _allDayMeta),
      );
    } else if (isInserting) {
      context.missing(_allDayMeta);
    }
    if (data.containsKey('start_date')) {
      context.handle(
        _startDateMeta,
        startDate.isAcceptableOrUnknown(data['start_date']!, _startDateMeta),
      );
    }
    if (data.containsKey('end_date_exclusive')) {
      context.handle(
        _endDateExclusiveMeta,
        endDateExclusive.isAcceptableOrUnknown(
          data['end_date_exclusive']!,
          _endDateExclusiveMeta,
        ),
      );
    }
    if (data.containsKey('timezone')) {
      context.handle(
        _timezoneMeta,
        timezone.isAcceptableOrUnknown(data['timezone']!, _timezoneMeta),
      );
    } else if (isInserting) {
      context.missing(_timezoneMeta);
    }
    if (data.containsKey('location_name')) {
      context.handle(
        _locationNameMeta,
        locationName.isAcceptableOrUnknown(
          data['location_name']!,
          _locationNameMeta,
        ),
      );
    }
    if (data.containsKey('building_name')) {
      context.handle(
        _buildingNameMeta,
        buildingName.isAcceptableOrUnknown(
          data['building_name']!,
          _buildingNameMeta,
        ),
      );
    }
    if (data.containsKey('campus_name')) {
      context.handle(
        _campusNameMeta,
        campusName.isAcceptableOrUnknown(data['campus_name']!, _campusNameMeta),
      );
    }
    if (data.containsKey('participants_json')) {
      context.handle(
        _participantsJsonMeta,
        participantsJson.isAcceptableOrUnknown(
          data['participants_json']!,
          _participantsJsonMeta,
        ),
      );
    }
    if (data.containsKey('source_details_json')) {
      context.handle(
        _sourceDetailsJsonMeta,
        sourceDetailsJson.isAcceptableOrUnknown(
          data['source_details_json']!,
          _sourceDetailsJsonMeta,
        ),
      );
    }
    if (data.containsKey('importance')) {
      context.handle(
        _importanceMeta,
        importance.isAcceptableOrUnknown(data['importance']!, _importanceMeta),
      );
    }
    if (data.containsKey('completion_policy')) {
      context.handle(
        _completionPolicyMeta,
        completionPolicy.isAcceptableOrUnknown(
          data['completion_policy']!,
          _completionPolicyMeta,
        ),
      );
    }
    if (data.containsKey('completed_at')) {
      context.handle(
        _completedAtMeta,
        completedAt.isAcceptableOrUnknown(
          data['completed_at']!,
          _completedAtMeta,
        ),
      );
    }
    if (data.containsKey('color')) {
      context.handle(
        _colorMeta,
        color.isAcceptableOrUnknown(data['color']!, _colorMeta),
      );
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
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
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, source, externalId},
    {accountId, personalSeriesId, occurrenceKey},
  ];
  @override
  CalendarEvent map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalendarEvent(
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
      externalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}external_id'],
      ),
      sourceSeriesExternalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_series_external_id'],
      ),
      personalSeriesId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}personal_series_id'],
      ),
      occurrenceKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}occurrence_key'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      ),
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      startAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_at'],
      ),
      endAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}end_at'],
      ),
      allDay: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}all_day'],
      )!,
      startDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}start_date'],
      ),
      endDateExclusive: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}end_date_exclusive'],
      ),
      timezone: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}timezone'],
      )!,
      locationName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location_name'],
      ),
      buildingName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}building_name'],
      ),
      campusName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}campus_name'],
      ),
      participantsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}participants_json'],
      )!,
      sourceDetailsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_details_json'],
      )!,
      importance: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}importance'],
      )!,
      completionPolicy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}completion_policy'],
      )!,
      completedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}completed_at'],
      ),
      color: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color'],
      ),
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $CalendarEventsTable createAlias(String alias) {
    return $CalendarEventsTable(attachedDatabase, alias);
  }
}

class CalendarEvent extends DataClass implements Insertable<CalendarEvent> {
  final String id;
  final String accountId;
  final String source;
  final String? externalId;
  final String? sourceSeriesExternalId;
  final String? personalSeriesId;
  final String? occurrenceKey;
  final String title;
  final String? description;
  final String type;
  final String status;
  final int? startAt;
  final int? endAt;
  final bool allDay;
  final String? startDate;
  final String? endDateExclusive;
  final String timezone;
  final String? locationName;
  final String? buildingName;
  final String? campusName;
  final String participantsJson;
  final String sourceDetailsJson;
  final String importance;
  final String completionPolicy;
  final int? completedAt;
  final String? color;
  final String tagsJson;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  const CalendarEvent({
    required this.id,
    required this.accountId,
    required this.source,
    this.externalId,
    this.sourceSeriesExternalId,
    this.personalSeriesId,
    this.occurrenceKey,
    required this.title,
    this.description,
    required this.type,
    required this.status,
    this.startAt,
    this.endAt,
    required this.allDay,
    this.startDate,
    this.endDateExclusive,
    required this.timezone,
    this.locationName,
    this.buildingName,
    this.campusName,
    required this.participantsJson,
    required this.sourceDetailsJson,
    required this.importance,
    required this.completionPolicy,
    this.completedAt,
    this.color,
    required this.tagsJson,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || externalId != null) {
      map['external_id'] = Variable<String>(externalId);
    }
    if (!nullToAbsent || sourceSeriesExternalId != null) {
      map['source_series_external_id'] = Variable<String>(
        sourceSeriesExternalId,
      );
    }
    if (!nullToAbsent || personalSeriesId != null) {
      map['personal_series_id'] = Variable<String>(personalSeriesId);
    }
    if (!nullToAbsent || occurrenceKey != null) {
      map['occurrence_key'] = Variable<String>(occurrenceKey);
    }
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || description != null) {
      map['description'] = Variable<String>(description);
    }
    map['type'] = Variable<String>(type);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || startAt != null) {
      map['start_at'] = Variable<int>(startAt);
    }
    if (!nullToAbsent || endAt != null) {
      map['end_at'] = Variable<int>(endAt);
    }
    map['all_day'] = Variable<bool>(allDay);
    if (!nullToAbsent || startDate != null) {
      map['start_date'] = Variable<String>(startDate);
    }
    if (!nullToAbsent || endDateExclusive != null) {
      map['end_date_exclusive'] = Variable<String>(endDateExclusive);
    }
    map['timezone'] = Variable<String>(timezone);
    if (!nullToAbsent || locationName != null) {
      map['location_name'] = Variable<String>(locationName);
    }
    if (!nullToAbsent || buildingName != null) {
      map['building_name'] = Variable<String>(buildingName);
    }
    if (!nullToAbsent || campusName != null) {
      map['campus_name'] = Variable<String>(campusName);
    }
    map['participants_json'] = Variable<String>(participantsJson);
    map['source_details_json'] = Variable<String>(sourceDetailsJson);
    map['importance'] = Variable<String>(importance);
    map['completion_policy'] = Variable<String>(completionPolicy);
    if (!nullToAbsent || completedAt != null) {
      map['completed_at'] = Variable<int>(completedAt);
    }
    if (!nullToAbsent || color != null) {
      map['color'] = Variable<String>(color);
    }
    map['tags_json'] = Variable<String>(tagsJson);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    return map;
  }

  CalendarEventsCompanion toCompanion(bool nullToAbsent) {
    return CalendarEventsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      source: Value(source),
      externalId: externalId == null && nullToAbsent
          ? const Value.absent()
          : Value(externalId),
      sourceSeriesExternalId: sourceSeriesExternalId == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceSeriesExternalId),
      personalSeriesId: personalSeriesId == null && nullToAbsent
          ? const Value.absent()
          : Value(personalSeriesId),
      occurrenceKey: occurrenceKey == null && nullToAbsent
          ? const Value.absent()
          : Value(occurrenceKey),
      title: Value(title),
      description: description == null && nullToAbsent
          ? const Value.absent()
          : Value(description),
      type: Value(type),
      status: Value(status),
      startAt: startAt == null && nullToAbsent
          ? const Value.absent()
          : Value(startAt),
      endAt: endAt == null && nullToAbsent
          ? const Value.absent()
          : Value(endAt),
      allDay: Value(allDay),
      startDate: startDate == null && nullToAbsent
          ? const Value.absent()
          : Value(startDate),
      endDateExclusive: endDateExclusive == null && nullToAbsent
          ? const Value.absent()
          : Value(endDateExclusive),
      timezone: Value(timezone),
      locationName: locationName == null && nullToAbsent
          ? const Value.absent()
          : Value(locationName),
      buildingName: buildingName == null && nullToAbsent
          ? const Value.absent()
          : Value(buildingName),
      campusName: campusName == null && nullToAbsent
          ? const Value.absent()
          : Value(campusName),
      participantsJson: Value(participantsJson),
      sourceDetailsJson: Value(sourceDetailsJson),
      importance: Value(importance),
      completionPolicy: Value(completionPolicy),
      completedAt: completedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(completedAt),
      color: color == null && nullToAbsent
          ? const Value.absent()
          : Value(color),
      tagsJson: Value(tagsJson),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory CalendarEvent.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalendarEvent(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      source: serializer.fromJson<String>(json['source']),
      externalId: serializer.fromJson<String?>(json['externalId']),
      sourceSeriesExternalId: serializer.fromJson<String?>(
        json['sourceSeriesExternalId'],
      ),
      personalSeriesId: serializer.fromJson<String?>(json['personalSeriesId']),
      occurrenceKey: serializer.fromJson<String?>(json['occurrenceKey']),
      title: serializer.fromJson<String>(json['title']),
      description: serializer.fromJson<String?>(json['description']),
      type: serializer.fromJson<String>(json['type']),
      status: serializer.fromJson<String>(json['status']),
      startAt: serializer.fromJson<int?>(json['startAt']),
      endAt: serializer.fromJson<int?>(json['endAt']),
      allDay: serializer.fromJson<bool>(json['allDay']),
      startDate: serializer.fromJson<String?>(json['startDate']),
      endDateExclusive: serializer.fromJson<String?>(json['endDateExclusive']),
      timezone: serializer.fromJson<String>(json['timezone']),
      locationName: serializer.fromJson<String?>(json['locationName']),
      buildingName: serializer.fromJson<String?>(json['buildingName']),
      campusName: serializer.fromJson<String?>(json['campusName']),
      participantsJson: serializer.fromJson<String>(json['participantsJson']),
      sourceDetailsJson: serializer.fromJson<String>(json['sourceDetailsJson']),
      importance: serializer.fromJson<String>(json['importance']),
      completionPolicy: serializer.fromJson<String>(json['completionPolicy']),
      completedAt: serializer.fromJson<int?>(json['completedAt']),
      color: serializer.fromJson<String?>(json['color']),
      tagsJson: serializer.fromJson<String>(json['tagsJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'source': serializer.toJson<String>(source),
      'externalId': serializer.toJson<String?>(externalId),
      'sourceSeriesExternalId': serializer.toJson<String?>(
        sourceSeriesExternalId,
      ),
      'personalSeriesId': serializer.toJson<String?>(personalSeriesId),
      'occurrenceKey': serializer.toJson<String?>(occurrenceKey),
      'title': serializer.toJson<String>(title),
      'description': serializer.toJson<String?>(description),
      'type': serializer.toJson<String>(type),
      'status': serializer.toJson<String>(status),
      'startAt': serializer.toJson<int?>(startAt),
      'endAt': serializer.toJson<int?>(endAt),
      'allDay': serializer.toJson<bool>(allDay),
      'startDate': serializer.toJson<String?>(startDate),
      'endDateExclusive': serializer.toJson<String?>(endDateExclusive),
      'timezone': serializer.toJson<String>(timezone),
      'locationName': serializer.toJson<String?>(locationName),
      'buildingName': serializer.toJson<String?>(buildingName),
      'campusName': serializer.toJson<String?>(campusName),
      'participantsJson': serializer.toJson<String>(participantsJson),
      'sourceDetailsJson': serializer.toJson<String>(sourceDetailsJson),
      'importance': serializer.toJson<String>(importance),
      'completionPolicy': serializer.toJson<String>(completionPolicy),
      'completedAt': serializer.toJson<int?>(completedAt),
      'color': serializer.toJson<String?>(color),
      'tagsJson': serializer.toJson<String>(tagsJson),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
    };
  }

  CalendarEvent copyWith({
    String? id,
    String? accountId,
    String? source,
    Value<String?> externalId = const Value.absent(),
    Value<String?> sourceSeriesExternalId = const Value.absent(),
    Value<String?> personalSeriesId = const Value.absent(),
    Value<String?> occurrenceKey = const Value.absent(),
    String? title,
    Value<String?> description = const Value.absent(),
    String? type,
    String? status,
    Value<int?> startAt = const Value.absent(),
    Value<int?> endAt = const Value.absent(),
    bool? allDay,
    Value<String?> startDate = const Value.absent(),
    Value<String?> endDateExclusive = const Value.absent(),
    String? timezone,
    Value<String?> locationName = const Value.absent(),
    Value<String?> buildingName = const Value.absent(),
    Value<String?> campusName = const Value.absent(),
    String? participantsJson,
    String? sourceDetailsJson,
    String? importance,
    String? completionPolicy,
    Value<int?> completedAt = const Value.absent(),
    Value<String?> color = const Value.absent(),
    String? tagsJson,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
  }) => CalendarEvent(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    source: source ?? this.source,
    externalId: externalId.present ? externalId.value : this.externalId,
    sourceSeriesExternalId: sourceSeriesExternalId.present
        ? sourceSeriesExternalId.value
        : this.sourceSeriesExternalId,
    personalSeriesId: personalSeriesId.present
        ? personalSeriesId.value
        : this.personalSeriesId,
    occurrenceKey: occurrenceKey.present
        ? occurrenceKey.value
        : this.occurrenceKey,
    title: title ?? this.title,
    description: description.present ? description.value : this.description,
    type: type ?? this.type,
    status: status ?? this.status,
    startAt: startAt.present ? startAt.value : this.startAt,
    endAt: endAt.present ? endAt.value : this.endAt,
    allDay: allDay ?? this.allDay,
    startDate: startDate.present ? startDate.value : this.startDate,
    endDateExclusive: endDateExclusive.present
        ? endDateExclusive.value
        : this.endDateExclusive,
    timezone: timezone ?? this.timezone,
    locationName: locationName.present ? locationName.value : this.locationName,
    buildingName: buildingName.present ? buildingName.value : this.buildingName,
    campusName: campusName.present ? campusName.value : this.campusName,
    participantsJson: participantsJson ?? this.participantsJson,
    sourceDetailsJson: sourceDetailsJson ?? this.sourceDetailsJson,
    importance: importance ?? this.importance,
    completionPolicy: completionPolicy ?? this.completionPolicy,
    completedAt: completedAt.present ? completedAt.value : this.completedAt,
    color: color.present ? color.value : this.color,
    tagsJson: tagsJson ?? this.tagsJson,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  CalendarEvent copyWithCompanion(CalendarEventsCompanion data) {
    return CalendarEvent(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      source: data.source.present ? data.source.value : this.source,
      externalId: data.externalId.present
          ? data.externalId.value
          : this.externalId,
      sourceSeriesExternalId: data.sourceSeriesExternalId.present
          ? data.sourceSeriesExternalId.value
          : this.sourceSeriesExternalId,
      personalSeriesId: data.personalSeriesId.present
          ? data.personalSeriesId.value
          : this.personalSeriesId,
      occurrenceKey: data.occurrenceKey.present
          ? data.occurrenceKey.value
          : this.occurrenceKey,
      title: data.title.present ? data.title.value : this.title,
      description: data.description.present
          ? data.description.value
          : this.description,
      type: data.type.present ? data.type.value : this.type,
      status: data.status.present ? data.status.value : this.status,
      startAt: data.startAt.present ? data.startAt.value : this.startAt,
      endAt: data.endAt.present ? data.endAt.value : this.endAt,
      allDay: data.allDay.present ? data.allDay.value : this.allDay,
      startDate: data.startDate.present ? data.startDate.value : this.startDate,
      endDateExclusive: data.endDateExclusive.present
          ? data.endDateExclusive.value
          : this.endDateExclusive,
      timezone: data.timezone.present ? data.timezone.value : this.timezone,
      locationName: data.locationName.present
          ? data.locationName.value
          : this.locationName,
      buildingName: data.buildingName.present
          ? data.buildingName.value
          : this.buildingName,
      campusName: data.campusName.present
          ? data.campusName.value
          : this.campusName,
      participantsJson: data.participantsJson.present
          ? data.participantsJson.value
          : this.participantsJson,
      sourceDetailsJson: data.sourceDetailsJson.present
          ? data.sourceDetailsJson.value
          : this.sourceDetailsJson,
      importance: data.importance.present
          ? data.importance.value
          : this.importance,
      completionPolicy: data.completionPolicy.present
          ? data.completionPolicy.value
          : this.completionPolicy,
      completedAt: data.completedAt.present
          ? data.completedAt.value
          : this.completedAt,
      color: data.color.present ? data.color.value : this.color,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalendarEvent(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('externalId: $externalId, ')
          ..write('sourceSeriesExternalId: $sourceSeriesExternalId, ')
          ..write('personalSeriesId: $personalSeriesId, ')
          ..write('occurrenceKey: $occurrenceKey, ')
          ..write('title: $title, ')
          ..write('description: $description, ')
          ..write('type: $type, ')
          ..write('status: $status, ')
          ..write('startAt: $startAt, ')
          ..write('endAt: $endAt, ')
          ..write('allDay: $allDay, ')
          ..write('startDate: $startDate, ')
          ..write('endDateExclusive: $endDateExclusive, ')
          ..write('timezone: $timezone, ')
          ..write('locationName: $locationName, ')
          ..write('buildingName: $buildingName, ')
          ..write('campusName: $campusName, ')
          ..write('participantsJson: $participantsJson, ')
          ..write('sourceDetailsJson: $sourceDetailsJson, ')
          ..write('importance: $importance, ')
          ..write('completionPolicy: $completionPolicy, ')
          ..write('completedAt: $completedAt, ')
          ..write('color: $color, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    accountId,
    source,
    externalId,
    sourceSeriesExternalId,
    personalSeriesId,
    occurrenceKey,
    title,
    description,
    type,
    status,
    startAt,
    endAt,
    allDay,
    startDate,
    endDateExclusive,
    timezone,
    locationName,
    buildingName,
    campusName,
    participantsJson,
    sourceDetailsJson,
    importance,
    completionPolicy,
    completedAt,
    color,
    tagsJson,
    createdAt,
    updatedAt,
    deletedAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalendarEvent &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.source == this.source &&
          other.externalId == this.externalId &&
          other.sourceSeriesExternalId == this.sourceSeriesExternalId &&
          other.personalSeriesId == this.personalSeriesId &&
          other.occurrenceKey == this.occurrenceKey &&
          other.title == this.title &&
          other.description == this.description &&
          other.type == this.type &&
          other.status == this.status &&
          other.startAt == this.startAt &&
          other.endAt == this.endAt &&
          other.allDay == this.allDay &&
          other.startDate == this.startDate &&
          other.endDateExclusive == this.endDateExclusive &&
          other.timezone == this.timezone &&
          other.locationName == this.locationName &&
          other.buildingName == this.buildingName &&
          other.campusName == this.campusName &&
          other.participantsJson == this.participantsJson &&
          other.sourceDetailsJson == this.sourceDetailsJson &&
          other.importance == this.importance &&
          other.completionPolicy == this.completionPolicy &&
          other.completedAt == this.completedAt &&
          other.color == this.color &&
          other.tagsJson == this.tagsJson &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class CalendarEventsCompanion extends UpdateCompanion<CalendarEvent> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> source;
  final Value<String?> externalId;
  final Value<String?> sourceSeriesExternalId;
  final Value<String?> personalSeriesId;
  final Value<String?> occurrenceKey;
  final Value<String> title;
  final Value<String?> description;
  final Value<String> type;
  final Value<String> status;
  final Value<int?> startAt;
  final Value<int?> endAt;
  final Value<bool> allDay;
  final Value<String?> startDate;
  final Value<String?> endDateExclusive;
  final Value<String> timezone;
  final Value<String?> locationName;
  final Value<String?> buildingName;
  final Value<String?> campusName;
  final Value<String> participantsJson;
  final Value<String> sourceDetailsJson;
  final Value<String> importance;
  final Value<String> completionPolicy;
  final Value<int?> completedAt;
  final Value<String?> color;
  final Value<String> tagsJson;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<int> rowid;
  const CalendarEventsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.source = const Value.absent(),
    this.externalId = const Value.absent(),
    this.sourceSeriesExternalId = const Value.absent(),
    this.personalSeriesId = const Value.absent(),
    this.occurrenceKey = const Value.absent(),
    this.title = const Value.absent(),
    this.description = const Value.absent(),
    this.type = const Value.absent(),
    this.status = const Value.absent(),
    this.startAt = const Value.absent(),
    this.endAt = const Value.absent(),
    this.allDay = const Value.absent(),
    this.startDate = const Value.absent(),
    this.endDateExclusive = const Value.absent(),
    this.timezone = const Value.absent(),
    this.locationName = const Value.absent(),
    this.buildingName = const Value.absent(),
    this.campusName = const Value.absent(),
    this.participantsJson = const Value.absent(),
    this.sourceDetailsJson = const Value.absent(),
    this.importance = const Value.absent(),
    this.completionPolicy = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.color = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CalendarEventsCompanion.insert({
    required String id,
    required String accountId,
    required String source,
    this.externalId = const Value.absent(),
    this.sourceSeriesExternalId = const Value.absent(),
    this.personalSeriesId = const Value.absent(),
    this.occurrenceKey = const Value.absent(),
    required String title,
    this.description = const Value.absent(),
    required String type,
    this.status = const Value.absent(),
    this.startAt = const Value.absent(),
    this.endAt = const Value.absent(),
    required bool allDay,
    this.startDate = const Value.absent(),
    this.endDateExclusive = const Value.absent(),
    required String timezone,
    this.locationName = const Value.absent(),
    this.buildingName = const Value.absent(),
    this.campusName = const Value.absent(),
    this.participantsJson = const Value.absent(),
    this.sourceDetailsJson = const Value.absent(),
    this.importance = const Value.absent(),
    this.completionPolicy = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.color = const Value.absent(),
    this.tagsJson = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       source = Value(source),
       title = Value(title),
       type = Value(type),
       allDay = Value(allDay),
       timezone = Value(timezone),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<CalendarEvent> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? source,
    Expression<String>? externalId,
    Expression<String>? sourceSeriesExternalId,
    Expression<String>? personalSeriesId,
    Expression<String>? occurrenceKey,
    Expression<String>? title,
    Expression<String>? description,
    Expression<String>? type,
    Expression<String>? status,
    Expression<int>? startAt,
    Expression<int>? endAt,
    Expression<bool>? allDay,
    Expression<String>? startDate,
    Expression<String>? endDateExclusive,
    Expression<String>? timezone,
    Expression<String>? locationName,
    Expression<String>? buildingName,
    Expression<String>? campusName,
    Expression<String>? participantsJson,
    Expression<String>? sourceDetailsJson,
    Expression<String>? importance,
    Expression<String>? completionPolicy,
    Expression<int>? completedAt,
    Expression<String>? color,
    Expression<String>? tagsJson,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (source != null) 'source': source,
      if (externalId != null) 'external_id': externalId,
      if (sourceSeriesExternalId != null)
        'source_series_external_id': sourceSeriesExternalId,
      if (personalSeriesId != null) 'personal_series_id': personalSeriesId,
      if (occurrenceKey != null) 'occurrence_key': occurrenceKey,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (type != null) 'type': type,
      if (status != null) 'status': status,
      if (startAt != null) 'start_at': startAt,
      if (endAt != null) 'end_at': endAt,
      if (allDay != null) 'all_day': allDay,
      if (startDate != null) 'start_date': startDate,
      if (endDateExclusive != null) 'end_date_exclusive': endDateExclusive,
      if (timezone != null) 'timezone': timezone,
      if (locationName != null) 'location_name': locationName,
      if (buildingName != null) 'building_name': buildingName,
      if (campusName != null) 'campus_name': campusName,
      if (participantsJson != null) 'participants_json': participantsJson,
      if (sourceDetailsJson != null) 'source_details_json': sourceDetailsJson,
      if (importance != null) 'importance': importance,
      if (completionPolicy != null) 'completion_policy': completionPolicy,
      if (completedAt != null) 'completed_at': completedAt,
      if (color != null) 'color': color,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CalendarEventsCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? source,
    Value<String?>? externalId,
    Value<String?>? sourceSeriesExternalId,
    Value<String?>? personalSeriesId,
    Value<String?>? occurrenceKey,
    Value<String>? title,
    Value<String?>? description,
    Value<String>? type,
    Value<String>? status,
    Value<int?>? startAt,
    Value<int?>? endAt,
    Value<bool>? allDay,
    Value<String?>? startDate,
    Value<String?>? endDateExclusive,
    Value<String>? timezone,
    Value<String?>? locationName,
    Value<String?>? buildingName,
    Value<String?>? campusName,
    Value<String>? participantsJson,
    Value<String>? sourceDetailsJson,
    Value<String>? importance,
    Value<String>? completionPolicy,
    Value<int?>? completedAt,
    Value<String?>? color,
    Value<String>? tagsJson,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<int>? rowid,
  }) {
    return CalendarEventsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      source: source ?? this.source,
      externalId: externalId ?? this.externalId,
      sourceSeriesExternalId:
          sourceSeriesExternalId ?? this.sourceSeriesExternalId,
      personalSeriesId: personalSeriesId ?? this.personalSeriesId,
      occurrenceKey: occurrenceKey ?? this.occurrenceKey,
      title: title ?? this.title,
      description: description ?? this.description,
      type: type ?? this.type,
      status: status ?? this.status,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      allDay: allDay ?? this.allDay,
      startDate: startDate ?? this.startDate,
      endDateExclusive: endDateExclusive ?? this.endDateExclusive,
      timezone: timezone ?? this.timezone,
      locationName: locationName ?? this.locationName,
      buildingName: buildingName ?? this.buildingName,
      campusName: campusName ?? this.campusName,
      participantsJson: participantsJson ?? this.participantsJson,
      sourceDetailsJson: sourceDetailsJson ?? this.sourceDetailsJson,
      importance: importance ?? this.importance,
      completionPolicy: completionPolicy ?? this.completionPolicy,
      completedAt: completedAt ?? this.completedAt,
      color: color ?? this.color,
      tagsJson: tagsJson ?? this.tagsJson,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
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
    if (externalId.present) {
      map['external_id'] = Variable<String>(externalId.value);
    }
    if (sourceSeriesExternalId.present) {
      map['source_series_external_id'] = Variable<String>(
        sourceSeriesExternalId.value,
      );
    }
    if (personalSeriesId.present) {
      map['personal_series_id'] = Variable<String>(personalSeriesId.value);
    }
    if (occurrenceKey.present) {
      map['occurrence_key'] = Variable<String>(occurrenceKey.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (startAt.present) {
      map['start_at'] = Variable<int>(startAt.value);
    }
    if (endAt.present) {
      map['end_at'] = Variable<int>(endAt.value);
    }
    if (allDay.present) {
      map['all_day'] = Variable<bool>(allDay.value);
    }
    if (startDate.present) {
      map['start_date'] = Variable<String>(startDate.value);
    }
    if (endDateExclusive.present) {
      map['end_date_exclusive'] = Variable<String>(endDateExclusive.value);
    }
    if (timezone.present) {
      map['timezone'] = Variable<String>(timezone.value);
    }
    if (locationName.present) {
      map['location_name'] = Variable<String>(locationName.value);
    }
    if (buildingName.present) {
      map['building_name'] = Variable<String>(buildingName.value);
    }
    if (campusName.present) {
      map['campus_name'] = Variable<String>(campusName.value);
    }
    if (participantsJson.present) {
      map['participants_json'] = Variable<String>(participantsJson.value);
    }
    if (sourceDetailsJson.present) {
      map['source_details_json'] = Variable<String>(sourceDetailsJson.value);
    }
    if (importance.present) {
      map['importance'] = Variable<String>(importance.value);
    }
    if (completionPolicy.present) {
      map['completion_policy'] = Variable<String>(completionPolicy.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<int>(completedAt.value);
    }
    if (color.present) {
      map['color'] = Variable<String>(color.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CalendarEventsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('externalId: $externalId, ')
          ..write('sourceSeriesExternalId: $sourceSeriesExternalId, ')
          ..write('personalSeriesId: $personalSeriesId, ')
          ..write('occurrenceKey: $occurrenceKey, ')
          ..write('title: $title, ')
          ..write('description: $description, ')
          ..write('type: $type, ')
          ..write('status: $status, ')
          ..write('startAt: $startAt, ')
          ..write('endAt: $endAt, ')
          ..write('allDay: $allDay, ')
          ..write('startDate: $startDate, ')
          ..write('endDateExclusive: $endDateExclusive, ')
          ..write('timezone: $timezone, ')
          ..write('locationName: $locationName, ')
          ..write('buildingName: $buildingName, ')
          ..write('campusName: $campusName, ')
          ..write('participantsJson: $participantsJson, ')
          ..write('sourceDetailsJson: $sourceDetailsJson, ')
          ..write('importance: $importance, ')
          ..write('completionPolicy: $completionPolicy, ')
          ..write('completedAt: $completedAt, ')
          ..write('color: $color, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CalendarEventOccurrenceExceptionsTable
    extends CalendarEventOccurrenceExceptions
    with
        TableInfo<
          $CalendarEventOccurrenceExceptionsTable,
          CalendarEventOccurrenceException
        > {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalendarEventOccurrenceExceptionsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _seriesIdMeta = const VerificationMeta(
    'seriesId',
  );
  @override
  late final GeneratedColumn<String> seriesId = GeneratedColumn<String>(
    'series_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES calendar_event_series (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _occurrenceKeyMeta = const VerificationMeta(
    'occurrenceKey',
  );
  @override
  late final GeneratedColumn<String> occurrenceKey = GeneratedColumn<String>(
    'occurrence_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _overrideJsonMeta = const VerificationMeta(
    'overrideJson',
  );
  @override
  late final GeneratedColumn<String> overrideJson = GeneratedColumn<String>(
    'override_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
    accountId,
    seriesId,
    occurrenceKey,
    kind,
    overrideJson,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calendar_event_occurrence_exceptions';
  @override
  VerificationContext validateIntegrity(
    Insertable<CalendarEventOccurrenceException> instance, {
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
    if (data.containsKey('series_id')) {
      context.handle(
        _seriesIdMeta,
        seriesId.isAcceptableOrUnknown(data['series_id']!, _seriesIdMeta),
      );
    } else if (isInserting) {
      context.missing(_seriesIdMeta);
    }
    if (data.containsKey('occurrence_key')) {
      context.handle(
        _occurrenceKeyMeta,
        occurrenceKey.isAcceptableOrUnknown(
          data['occurrence_key']!,
          _occurrenceKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_occurrenceKeyMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('override_json')) {
      context.handle(
        _overrideJsonMeta,
        overrideJson.isAcceptableOrUnknown(
          data['override_json']!,
          _overrideJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_overrideJsonMeta);
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
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, seriesId, occurrenceKey},
  ];
  @override
  CalendarEventOccurrenceException map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalendarEventOccurrenceException(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      seriesId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}series_id'],
      )!,
      occurrenceKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}occurrence_key'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      overrideJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}override_json'],
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
  $CalendarEventOccurrenceExceptionsTable createAlias(String alias) {
    return $CalendarEventOccurrenceExceptionsTable(attachedDatabase, alias);
  }
}

class CalendarEventOccurrenceException extends DataClass
    implements Insertable<CalendarEventOccurrenceException> {
  final String id;
  final String accountId;
  final String seriesId;
  final String occurrenceKey;
  final String kind;
  final String overrideJson;
  final int createdAt;
  final int updatedAt;
  const CalendarEventOccurrenceException({
    required this.id,
    required this.accountId,
    required this.seriesId,
    required this.occurrenceKey,
    required this.kind,
    required this.overrideJson,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['series_id'] = Variable<String>(seriesId);
    map['occurrence_key'] = Variable<String>(occurrenceKey);
    map['kind'] = Variable<String>(kind);
    map['override_json'] = Variable<String>(overrideJson);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  CalendarEventOccurrenceExceptionsCompanion toCompanion(bool nullToAbsent) {
    return CalendarEventOccurrenceExceptionsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      seriesId: Value(seriesId),
      occurrenceKey: Value(occurrenceKey),
      kind: Value(kind),
      overrideJson: Value(overrideJson),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory CalendarEventOccurrenceException.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalendarEventOccurrenceException(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      seriesId: serializer.fromJson<String>(json['seriesId']),
      occurrenceKey: serializer.fromJson<String>(json['occurrenceKey']),
      kind: serializer.fromJson<String>(json['kind']),
      overrideJson: serializer.fromJson<String>(json['overrideJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'seriesId': serializer.toJson<String>(seriesId),
      'occurrenceKey': serializer.toJson<String>(occurrenceKey),
      'kind': serializer.toJson<String>(kind),
      'overrideJson': serializer.toJson<String>(overrideJson),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  CalendarEventOccurrenceException copyWith({
    String? id,
    String? accountId,
    String? seriesId,
    String? occurrenceKey,
    String? kind,
    String? overrideJson,
    int? createdAt,
    int? updatedAt,
  }) => CalendarEventOccurrenceException(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    seriesId: seriesId ?? this.seriesId,
    occurrenceKey: occurrenceKey ?? this.occurrenceKey,
    kind: kind ?? this.kind,
    overrideJson: overrideJson ?? this.overrideJson,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  CalendarEventOccurrenceException copyWithCompanion(
    CalendarEventOccurrenceExceptionsCompanion data,
  ) {
    return CalendarEventOccurrenceException(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      seriesId: data.seriesId.present ? data.seriesId.value : this.seriesId,
      occurrenceKey: data.occurrenceKey.present
          ? data.occurrenceKey.value
          : this.occurrenceKey,
      kind: data.kind.present ? data.kind.value : this.kind,
      overrideJson: data.overrideJson.present
          ? data.overrideJson.value
          : this.overrideJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalendarEventOccurrenceException(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('seriesId: $seriesId, ')
          ..write('occurrenceKey: $occurrenceKey, ')
          ..write('kind: $kind, ')
          ..write('overrideJson: $overrideJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    seriesId,
    occurrenceKey,
    kind,
    overrideJson,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalendarEventOccurrenceException &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.seriesId == this.seriesId &&
          other.occurrenceKey == this.occurrenceKey &&
          other.kind == this.kind &&
          other.overrideJson == this.overrideJson &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class CalendarEventOccurrenceExceptionsCompanion
    extends UpdateCompanion<CalendarEventOccurrenceException> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> seriesId;
  final Value<String> occurrenceKey;
  final Value<String> kind;
  final Value<String> overrideJson;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const CalendarEventOccurrenceExceptionsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.seriesId = const Value.absent(),
    this.occurrenceKey = const Value.absent(),
    this.kind = const Value.absent(),
    this.overrideJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CalendarEventOccurrenceExceptionsCompanion.insert({
    required String id,
    required String accountId,
    required String seriesId,
    required String occurrenceKey,
    required String kind,
    required String overrideJson,
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       seriesId = Value(seriesId),
       occurrenceKey = Value(occurrenceKey),
       kind = Value(kind),
       overrideJson = Value(overrideJson),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<CalendarEventOccurrenceException> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? seriesId,
    Expression<String>? occurrenceKey,
    Expression<String>? kind,
    Expression<String>? overrideJson,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (seriesId != null) 'series_id': seriesId,
      if (occurrenceKey != null) 'occurrence_key': occurrenceKey,
      if (kind != null) 'kind': kind,
      if (overrideJson != null) 'override_json': overrideJson,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CalendarEventOccurrenceExceptionsCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? seriesId,
    Value<String>? occurrenceKey,
    Value<String>? kind,
    Value<String>? overrideJson,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return CalendarEventOccurrenceExceptionsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      seriesId: seriesId ?? this.seriesId,
      occurrenceKey: occurrenceKey ?? this.occurrenceKey,
      kind: kind ?? this.kind,
      overrideJson: overrideJson ?? this.overrideJson,
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
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (seriesId.present) {
      map['series_id'] = Variable<String>(seriesId.value);
    }
    if (occurrenceKey.present) {
      map['occurrence_key'] = Variable<String>(occurrenceKey.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (overrideJson.present) {
      map['override_json'] = Variable<String>(overrideJson.value);
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
    return (StringBuffer('CalendarEventOccurrenceExceptionsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('seriesId: $seriesId, ')
          ..write('occurrenceKey: $occurrenceKey, ')
          ..write('kind: $kind, ')
          ..write('overrideJson: $overrideJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $UserOverlaysTable extends UserOverlays
    with TableInfo<$UserOverlaysTable, UserOverlay> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UserOverlaysTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _eventIdMeta = const VerificationMeta(
    'eventId',
  );
  @override
  late final GeneratedColumn<String> eventId = GeneratedColumn<String>(
    'event_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES calendar_events (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _displayTitleMeta = const VerificationMeta(
    'displayTitle',
  );
  @override
  late final GeneratedColumn<String> displayTitle = GeneratedColumn<String>(
    'display_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _attendancePolicyMeta = const VerificationMeta(
    'attendancePolicy',
  );
  @override
  late final GeneratedColumn<String> attendancePolicy = GeneratedColumn<String>(
    'attendance_policy',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _attendanceDecisionMeta =
      const VerificationMeta('attendanceDecision');
  @override
  late final GeneratedColumn<String> attendanceDecision =
      GeneratedColumn<String>(
        'attendance_decision',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _attendanceDecisionAtMeta =
      const VerificationMeta('attendanceDecisionAt');
  @override
  late final GeneratedColumn<int> attendanceDecisionAt = GeneratedColumn<int>(
    'attendance_decision_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _attendanceNoteMeta = const VerificationMeta(
    'attendanceNote',
  );
  @override
  late final GeneratedColumn<String> attendanceNote = GeneratedColumn<String>(
    'attendance_note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _attendanceOutcomeMeta = const VerificationMeta(
    'attendanceOutcome',
  );
  @override
  late final GeneratedColumn<String> attendanceOutcome =
      GeneratedColumn<String>(
        'attendance_outcome',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _listeningModeMeta = const VerificationMeta(
    'listeningMode',
  );
  @override
  late final GeneratedColumn<String> listeningMode = GeneratedColumn<String>(
    'listening_mode',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _listeningNoteMeta = const VerificationMeta(
    'listeningNote',
  );
  @override
  late final GeneratedColumn<String> listeningNote = GeneratedColumn<String>(
    'listening_note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _importanceMeta = const VerificationMeta(
    'importance',
  );
  @override
  late final GeneratedColumn<String> importance = GeneratedColumn<String>(
    'importance',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<String> color = GeneratedColumn<String>(
    'color',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _hiddenMeta = const VerificationMeta('hidden');
  @override
  late final GeneratedColumn<bool> hidden = GeneratedColumn<bool>(
    'hidden',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("hidden" IN (0, 1))',
    ),
  );
  static const VerificationMeta _userNotesMeta = const VerificationMeta(
    'userNotes',
  );
  @override
  late final GeneratedColumn<String> userNotes = GeneratedColumn<String>(
    'user_notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
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
    accountId,
    eventId,
    displayTitle,
    attendancePolicy,
    attendanceDecision,
    attendanceDecisionAt,
    attendanceNote,
    attendanceOutcome,
    listeningMode,
    listeningNote,
    importance,
    color,
    hidden,
    userNotes,
    tagsJson,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'user_overlays';
  @override
  VerificationContext validateIntegrity(
    Insertable<UserOverlay> instance, {
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
    if (data.containsKey('event_id')) {
      context.handle(
        _eventIdMeta,
        eventId.isAcceptableOrUnknown(data['event_id']!, _eventIdMeta),
      );
    } else if (isInserting) {
      context.missing(_eventIdMeta);
    }
    if (data.containsKey('display_title')) {
      context.handle(
        _displayTitleMeta,
        displayTitle.isAcceptableOrUnknown(
          data['display_title']!,
          _displayTitleMeta,
        ),
      );
    }
    if (data.containsKey('attendance_policy')) {
      context.handle(
        _attendancePolicyMeta,
        attendancePolicy.isAcceptableOrUnknown(
          data['attendance_policy']!,
          _attendancePolicyMeta,
        ),
      );
    }
    if (data.containsKey('attendance_decision')) {
      context.handle(
        _attendanceDecisionMeta,
        attendanceDecision.isAcceptableOrUnknown(
          data['attendance_decision']!,
          _attendanceDecisionMeta,
        ),
      );
    }
    if (data.containsKey('attendance_decision_at')) {
      context.handle(
        _attendanceDecisionAtMeta,
        attendanceDecisionAt.isAcceptableOrUnknown(
          data['attendance_decision_at']!,
          _attendanceDecisionAtMeta,
        ),
      );
    }
    if (data.containsKey('attendance_note')) {
      context.handle(
        _attendanceNoteMeta,
        attendanceNote.isAcceptableOrUnknown(
          data['attendance_note']!,
          _attendanceNoteMeta,
        ),
      );
    }
    if (data.containsKey('attendance_outcome')) {
      context.handle(
        _attendanceOutcomeMeta,
        attendanceOutcome.isAcceptableOrUnknown(
          data['attendance_outcome']!,
          _attendanceOutcomeMeta,
        ),
      );
    }
    if (data.containsKey('listening_mode')) {
      context.handle(
        _listeningModeMeta,
        listeningMode.isAcceptableOrUnknown(
          data['listening_mode']!,
          _listeningModeMeta,
        ),
      );
    }
    if (data.containsKey('listening_note')) {
      context.handle(
        _listeningNoteMeta,
        listeningNote.isAcceptableOrUnknown(
          data['listening_note']!,
          _listeningNoteMeta,
        ),
      );
    }
    if (data.containsKey('importance')) {
      context.handle(
        _importanceMeta,
        importance.isAcceptableOrUnknown(data['importance']!, _importanceMeta),
      );
    }
    if (data.containsKey('color')) {
      context.handle(
        _colorMeta,
        color.isAcceptableOrUnknown(data['color']!, _colorMeta),
      );
    }
    if (data.containsKey('hidden')) {
      context.handle(
        _hiddenMeta,
        hidden.isAcceptableOrUnknown(data['hidden']!, _hiddenMeta),
      );
    }
    if (data.containsKey('user_notes')) {
      context.handle(
        _userNotesMeta,
        userNotes.isAcceptableOrUnknown(data['user_notes']!, _userNotesMeta),
      );
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
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
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, eventId},
  ];
  @override
  UserOverlay map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UserOverlay(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      eventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_id'],
      )!,
      displayTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_title'],
      ),
      attendancePolicy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attendance_policy'],
      ),
      attendanceDecision: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attendance_decision'],
      ),
      attendanceDecisionAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attendance_decision_at'],
      ),
      attendanceNote: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attendance_note'],
      ),
      attendanceOutcome: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attendance_outcome'],
      ),
      listeningMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}listening_mode'],
      ),
      listeningNote: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}listening_note'],
      ),
      importance: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}importance'],
      ),
      color: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color'],
      ),
      hidden: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}hidden'],
      ),
      userNotes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_notes'],
      ),
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      ),
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
  $UserOverlaysTable createAlias(String alias) {
    return $UserOverlaysTable(attachedDatabase, alias);
  }
}

class UserOverlay extends DataClass implements Insertable<UserOverlay> {
  final String id;
  final String accountId;
  final String eventId;
  final String? displayTitle;
  final String? attendancePolicy;
  final String? attendanceDecision;
  final int? attendanceDecisionAt;
  final String? attendanceNote;
  final String? attendanceOutcome;
  final String? listeningMode;
  final String? listeningNote;
  final String? importance;
  final String? color;
  final bool? hidden;
  final String? userNotes;
  final String? tagsJson;
  final int createdAt;
  final int updatedAt;
  const UserOverlay({
    required this.id,
    required this.accountId,
    required this.eventId,
    this.displayTitle,
    this.attendancePolicy,
    this.attendanceDecision,
    this.attendanceDecisionAt,
    this.attendanceNote,
    this.attendanceOutcome,
    this.listeningMode,
    this.listeningNote,
    this.importance,
    this.color,
    this.hidden,
    this.userNotes,
    this.tagsJson,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['event_id'] = Variable<String>(eventId);
    if (!nullToAbsent || displayTitle != null) {
      map['display_title'] = Variable<String>(displayTitle);
    }
    if (!nullToAbsent || attendancePolicy != null) {
      map['attendance_policy'] = Variable<String>(attendancePolicy);
    }
    if (!nullToAbsent || attendanceDecision != null) {
      map['attendance_decision'] = Variable<String>(attendanceDecision);
    }
    if (!nullToAbsent || attendanceDecisionAt != null) {
      map['attendance_decision_at'] = Variable<int>(attendanceDecisionAt);
    }
    if (!nullToAbsent || attendanceNote != null) {
      map['attendance_note'] = Variable<String>(attendanceNote);
    }
    if (!nullToAbsent || attendanceOutcome != null) {
      map['attendance_outcome'] = Variable<String>(attendanceOutcome);
    }
    if (!nullToAbsent || listeningMode != null) {
      map['listening_mode'] = Variable<String>(listeningMode);
    }
    if (!nullToAbsent || listeningNote != null) {
      map['listening_note'] = Variable<String>(listeningNote);
    }
    if (!nullToAbsent || importance != null) {
      map['importance'] = Variable<String>(importance);
    }
    if (!nullToAbsent || color != null) {
      map['color'] = Variable<String>(color);
    }
    if (!nullToAbsent || hidden != null) {
      map['hidden'] = Variable<bool>(hidden);
    }
    if (!nullToAbsent || userNotes != null) {
      map['user_notes'] = Variable<String>(userNotes);
    }
    if (!nullToAbsent || tagsJson != null) {
      map['tags_json'] = Variable<String>(tagsJson);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  UserOverlaysCompanion toCompanion(bool nullToAbsent) {
    return UserOverlaysCompanion(
      id: Value(id),
      accountId: Value(accountId),
      eventId: Value(eventId),
      displayTitle: displayTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(displayTitle),
      attendancePolicy: attendancePolicy == null && nullToAbsent
          ? const Value.absent()
          : Value(attendancePolicy),
      attendanceDecision: attendanceDecision == null && nullToAbsent
          ? const Value.absent()
          : Value(attendanceDecision),
      attendanceDecisionAt: attendanceDecisionAt == null && nullToAbsent
          ? const Value.absent()
          : Value(attendanceDecisionAt),
      attendanceNote: attendanceNote == null && nullToAbsent
          ? const Value.absent()
          : Value(attendanceNote),
      attendanceOutcome: attendanceOutcome == null && nullToAbsent
          ? const Value.absent()
          : Value(attendanceOutcome),
      listeningMode: listeningMode == null && nullToAbsent
          ? const Value.absent()
          : Value(listeningMode),
      listeningNote: listeningNote == null && nullToAbsent
          ? const Value.absent()
          : Value(listeningNote),
      importance: importance == null && nullToAbsent
          ? const Value.absent()
          : Value(importance),
      color: color == null && nullToAbsent
          ? const Value.absent()
          : Value(color),
      hidden: hidden == null && nullToAbsent
          ? const Value.absent()
          : Value(hidden),
      userNotes: userNotes == null && nullToAbsent
          ? const Value.absent()
          : Value(userNotes),
      tagsJson: tagsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(tagsJson),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory UserOverlay.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UserOverlay(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      eventId: serializer.fromJson<String>(json['eventId']),
      displayTitle: serializer.fromJson<String?>(json['displayTitle']),
      attendancePolicy: serializer.fromJson<String?>(json['attendancePolicy']),
      attendanceDecision: serializer.fromJson<String?>(
        json['attendanceDecision'],
      ),
      attendanceDecisionAt: serializer.fromJson<int?>(
        json['attendanceDecisionAt'],
      ),
      attendanceNote: serializer.fromJson<String?>(json['attendanceNote']),
      attendanceOutcome: serializer.fromJson<String?>(
        json['attendanceOutcome'],
      ),
      listeningMode: serializer.fromJson<String?>(json['listeningMode']),
      listeningNote: serializer.fromJson<String?>(json['listeningNote']),
      importance: serializer.fromJson<String?>(json['importance']),
      color: serializer.fromJson<String?>(json['color']),
      hidden: serializer.fromJson<bool?>(json['hidden']),
      userNotes: serializer.fromJson<String?>(json['userNotes']),
      tagsJson: serializer.fromJson<String?>(json['tagsJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'eventId': serializer.toJson<String>(eventId),
      'displayTitle': serializer.toJson<String?>(displayTitle),
      'attendancePolicy': serializer.toJson<String?>(attendancePolicy),
      'attendanceDecision': serializer.toJson<String?>(attendanceDecision),
      'attendanceDecisionAt': serializer.toJson<int?>(attendanceDecisionAt),
      'attendanceNote': serializer.toJson<String?>(attendanceNote),
      'attendanceOutcome': serializer.toJson<String?>(attendanceOutcome),
      'listeningMode': serializer.toJson<String?>(listeningMode),
      'listeningNote': serializer.toJson<String?>(listeningNote),
      'importance': serializer.toJson<String?>(importance),
      'color': serializer.toJson<String?>(color),
      'hidden': serializer.toJson<bool?>(hidden),
      'userNotes': serializer.toJson<String?>(userNotes),
      'tagsJson': serializer.toJson<String?>(tagsJson),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  UserOverlay copyWith({
    String? id,
    String? accountId,
    String? eventId,
    Value<String?> displayTitle = const Value.absent(),
    Value<String?> attendancePolicy = const Value.absent(),
    Value<String?> attendanceDecision = const Value.absent(),
    Value<int?> attendanceDecisionAt = const Value.absent(),
    Value<String?> attendanceNote = const Value.absent(),
    Value<String?> attendanceOutcome = const Value.absent(),
    Value<String?> listeningMode = const Value.absent(),
    Value<String?> listeningNote = const Value.absent(),
    Value<String?> importance = const Value.absent(),
    Value<String?> color = const Value.absent(),
    Value<bool?> hidden = const Value.absent(),
    Value<String?> userNotes = const Value.absent(),
    Value<String?> tagsJson = const Value.absent(),
    int? createdAt,
    int? updatedAt,
  }) => UserOverlay(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    eventId: eventId ?? this.eventId,
    displayTitle: displayTitle.present ? displayTitle.value : this.displayTitle,
    attendancePolicy: attendancePolicy.present
        ? attendancePolicy.value
        : this.attendancePolicy,
    attendanceDecision: attendanceDecision.present
        ? attendanceDecision.value
        : this.attendanceDecision,
    attendanceDecisionAt: attendanceDecisionAt.present
        ? attendanceDecisionAt.value
        : this.attendanceDecisionAt,
    attendanceNote: attendanceNote.present
        ? attendanceNote.value
        : this.attendanceNote,
    attendanceOutcome: attendanceOutcome.present
        ? attendanceOutcome.value
        : this.attendanceOutcome,
    listeningMode: listeningMode.present
        ? listeningMode.value
        : this.listeningMode,
    listeningNote: listeningNote.present
        ? listeningNote.value
        : this.listeningNote,
    importance: importance.present ? importance.value : this.importance,
    color: color.present ? color.value : this.color,
    hidden: hidden.present ? hidden.value : this.hidden,
    userNotes: userNotes.present ? userNotes.value : this.userNotes,
    tagsJson: tagsJson.present ? tagsJson.value : this.tagsJson,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  UserOverlay copyWithCompanion(UserOverlaysCompanion data) {
    return UserOverlay(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      eventId: data.eventId.present ? data.eventId.value : this.eventId,
      displayTitle: data.displayTitle.present
          ? data.displayTitle.value
          : this.displayTitle,
      attendancePolicy: data.attendancePolicy.present
          ? data.attendancePolicy.value
          : this.attendancePolicy,
      attendanceDecision: data.attendanceDecision.present
          ? data.attendanceDecision.value
          : this.attendanceDecision,
      attendanceDecisionAt: data.attendanceDecisionAt.present
          ? data.attendanceDecisionAt.value
          : this.attendanceDecisionAt,
      attendanceNote: data.attendanceNote.present
          ? data.attendanceNote.value
          : this.attendanceNote,
      attendanceOutcome: data.attendanceOutcome.present
          ? data.attendanceOutcome.value
          : this.attendanceOutcome,
      listeningMode: data.listeningMode.present
          ? data.listeningMode.value
          : this.listeningMode,
      listeningNote: data.listeningNote.present
          ? data.listeningNote.value
          : this.listeningNote,
      importance: data.importance.present
          ? data.importance.value
          : this.importance,
      color: data.color.present ? data.color.value : this.color,
      hidden: data.hidden.present ? data.hidden.value : this.hidden,
      userNotes: data.userNotes.present ? data.userNotes.value : this.userNotes,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UserOverlay(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('eventId: $eventId, ')
          ..write('displayTitle: $displayTitle, ')
          ..write('attendancePolicy: $attendancePolicy, ')
          ..write('attendanceDecision: $attendanceDecision, ')
          ..write('attendanceDecisionAt: $attendanceDecisionAt, ')
          ..write('attendanceNote: $attendanceNote, ')
          ..write('attendanceOutcome: $attendanceOutcome, ')
          ..write('listeningMode: $listeningMode, ')
          ..write('listeningNote: $listeningNote, ')
          ..write('importance: $importance, ')
          ..write('color: $color, ')
          ..write('hidden: $hidden, ')
          ..write('userNotes: $userNotes, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    eventId,
    displayTitle,
    attendancePolicy,
    attendanceDecision,
    attendanceDecisionAt,
    attendanceNote,
    attendanceOutcome,
    listeningMode,
    listeningNote,
    importance,
    color,
    hidden,
    userNotes,
    tagsJson,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UserOverlay &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.eventId == this.eventId &&
          other.displayTitle == this.displayTitle &&
          other.attendancePolicy == this.attendancePolicy &&
          other.attendanceDecision == this.attendanceDecision &&
          other.attendanceDecisionAt == this.attendanceDecisionAt &&
          other.attendanceNote == this.attendanceNote &&
          other.attendanceOutcome == this.attendanceOutcome &&
          other.listeningMode == this.listeningMode &&
          other.listeningNote == this.listeningNote &&
          other.importance == this.importance &&
          other.color == this.color &&
          other.hidden == this.hidden &&
          other.userNotes == this.userNotes &&
          other.tagsJson == this.tagsJson &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class UserOverlaysCompanion extends UpdateCompanion<UserOverlay> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> eventId;
  final Value<String?> displayTitle;
  final Value<String?> attendancePolicy;
  final Value<String?> attendanceDecision;
  final Value<int?> attendanceDecisionAt;
  final Value<String?> attendanceNote;
  final Value<String?> attendanceOutcome;
  final Value<String?> listeningMode;
  final Value<String?> listeningNote;
  final Value<String?> importance;
  final Value<String?> color;
  final Value<bool?> hidden;
  final Value<String?> userNotes;
  final Value<String?> tagsJson;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const UserOverlaysCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.eventId = const Value.absent(),
    this.displayTitle = const Value.absent(),
    this.attendancePolicy = const Value.absent(),
    this.attendanceDecision = const Value.absent(),
    this.attendanceDecisionAt = const Value.absent(),
    this.attendanceNote = const Value.absent(),
    this.attendanceOutcome = const Value.absent(),
    this.listeningMode = const Value.absent(),
    this.listeningNote = const Value.absent(),
    this.importance = const Value.absent(),
    this.color = const Value.absent(),
    this.hidden = const Value.absent(),
    this.userNotes = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UserOverlaysCompanion.insert({
    required String id,
    required String accountId,
    required String eventId,
    this.displayTitle = const Value.absent(),
    this.attendancePolicy = const Value.absent(),
    this.attendanceDecision = const Value.absent(),
    this.attendanceDecisionAt = const Value.absent(),
    this.attendanceNote = const Value.absent(),
    this.attendanceOutcome = const Value.absent(),
    this.listeningMode = const Value.absent(),
    this.listeningNote = const Value.absent(),
    this.importance = const Value.absent(),
    this.color = const Value.absent(),
    this.hidden = const Value.absent(),
    this.userNotes = const Value.absent(),
    this.tagsJson = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       eventId = Value(eventId),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<UserOverlay> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? eventId,
    Expression<String>? displayTitle,
    Expression<String>? attendancePolicy,
    Expression<String>? attendanceDecision,
    Expression<int>? attendanceDecisionAt,
    Expression<String>? attendanceNote,
    Expression<String>? attendanceOutcome,
    Expression<String>? listeningMode,
    Expression<String>? listeningNote,
    Expression<String>? importance,
    Expression<String>? color,
    Expression<bool>? hidden,
    Expression<String>? userNotes,
    Expression<String>? tagsJson,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (eventId != null) 'event_id': eventId,
      if (displayTitle != null) 'display_title': displayTitle,
      if (attendancePolicy != null) 'attendance_policy': attendancePolicy,
      if (attendanceDecision != null) 'attendance_decision': attendanceDecision,
      if (attendanceDecisionAt != null)
        'attendance_decision_at': attendanceDecisionAt,
      if (attendanceNote != null) 'attendance_note': attendanceNote,
      if (attendanceOutcome != null) 'attendance_outcome': attendanceOutcome,
      if (listeningMode != null) 'listening_mode': listeningMode,
      if (listeningNote != null) 'listening_note': listeningNote,
      if (importance != null) 'importance': importance,
      if (color != null) 'color': color,
      if (hidden != null) 'hidden': hidden,
      if (userNotes != null) 'user_notes': userNotes,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UserOverlaysCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? eventId,
    Value<String?>? displayTitle,
    Value<String?>? attendancePolicy,
    Value<String?>? attendanceDecision,
    Value<int?>? attendanceDecisionAt,
    Value<String?>? attendanceNote,
    Value<String?>? attendanceOutcome,
    Value<String?>? listeningMode,
    Value<String?>? listeningNote,
    Value<String?>? importance,
    Value<String?>? color,
    Value<bool?>? hidden,
    Value<String?>? userNotes,
    Value<String?>? tagsJson,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return UserOverlaysCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      eventId: eventId ?? this.eventId,
      displayTitle: displayTitle ?? this.displayTitle,
      attendancePolicy: attendancePolicy ?? this.attendancePolicy,
      attendanceDecision: attendanceDecision ?? this.attendanceDecision,
      attendanceDecisionAt: attendanceDecisionAt ?? this.attendanceDecisionAt,
      attendanceNote: attendanceNote ?? this.attendanceNote,
      attendanceOutcome: attendanceOutcome ?? this.attendanceOutcome,
      listeningMode: listeningMode ?? this.listeningMode,
      listeningNote: listeningNote ?? this.listeningNote,
      importance: importance ?? this.importance,
      color: color ?? this.color,
      hidden: hidden ?? this.hidden,
      userNotes: userNotes ?? this.userNotes,
      tagsJson: tagsJson ?? this.tagsJson,
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
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (eventId.present) {
      map['event_id'] = Variable<String>(eventId.value);
    }
    if (displayTitle.present) {
      map['display_title'] = Variable<String>(displayTitle.value);
    }
    if (attendancePolicy.present) {
      map['attendance_policy'] = Variable<String>(attendancePolicy.value);
    }
    if (attendanceDecision.present) {
      map['attendance_decision'] = Variable<String>(attendanceDecision.value);
    }
    if (attendanceDecisionAt.present) {
      map['attendance_decision_at'] = Variable<int>(attendanceDecisionAt.value);
    }
    if (attendanceNote.present) {
      map['attendance_note'] = Variable<String>(attendanceNote.value);
    }
    if (attendanceOutcome.present) {
      map['attendance_outcome'] = Variable<String>(attendanceOutcome.value);
    }
    if (listeningMode.present) {
      map['listening_mode'] = Variable<String>(listeningMode.value);
    }
    if (listeningNote.present) {
      map['listening_note'] = Variable<String>(listeningNote.value);
    }
    if (importance.present) {
      map['importance'] = Variable<String>(importance.value);
    }
    if (color.present) {
      map['color'] = Variable<String>(color.value);
    }
    if (hidden.present) {
      map['hidden'] = Variable<bool>(hidden.value);
    }
    if (userNotes.present) {
      map['user_notes'] = Variable<String>(userNotes.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
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
    return (StringBuffer('UserOverlaysCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('eventId: $eventId, ')
          ..write('displayTitle: $displayTitle, ')
          ..write('attendancePolicy: $attendancePolicy, ')
          ..write('attendanceDecision: $attendanceDecision, ')
          ..write('attendanceDecisionAt: $attendanceDecisionAt, ')
          ..write('attendanceNote: $attendanceNote, ')
          ..write('attendanceOutcome: $attendanceOutcome, ')
          ..write('listeningMode: $listeningMode, ')
          ..write('listeningNote: $listeningNote, ')
          ..write('importance: $importance, ')
          ..write('color: $color, ')
          ..write('hidden: $hidden, ')
          ..write('userNotes: $userNotes, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TasksTable extends Tasks with TableInfo<$TasksTable, Task> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TasksTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _userNotesMeta = const VerificationMeta(
    'userNotes',
  );
  @override
  late final GeneratedColumn<String> userNotes = GeneratedColumn<String>(
    'user_notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
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
  static const VerificationMeta _blockedReasonMeta = const VerificationMeta(
    'blockedReason',
  );
  @override
  late final GeneratedColumn<String> blockedReason = GeneratedColumn<String>(
    'blocked_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _importanceMeta = const VerificationMeta(
    'importance',
  );
  @override
  late final GeneratedColumn<String> importance = GeneratedColumn<String>(
    'importance',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deadlineAtMeta = const VerificationMeta(
    'deadlineAt',
  );
  @override
  late final GeneratedColumn<int> deadlineAt = GeneratedColumn<int>(
    'deadline_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _terminalAtMeta = const VerificationMeta(
    'terminalAt',
  );
  @override
  late final GeneratedColumn<int> terminalAt = GeneratedColumn<int>(
    'terminal_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
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
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    title,
    description,
    userNotes,
    state,
    blockedReason,
    importance,
    deadlineAt,
    tagsJson,
    terminalAt,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tasks';
  @override
  VerificationContext validateIntegrity(
    Insertable<Task> instance, {
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
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('user_notes')) {
      context.handle(
        _userNotesMeta,
        userNotes.isAcceptableOrUnknown(data['user_notes']!, _userNotesMeta),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('blocked_reason')) {
      context.handle(
        _blockedReasonMeta,
        blockedReason.isAcceptableOrUnknown(
          data['blocked_reason']!,
          _blockedReasonMeta,
        ),
      );
    }
    if (data.containsKey('importance')) {
      context.handle(
        _importanceMeta,
        importance.isAcceptableOrUnknown(data['importance']!, _importanceMeta),
      );
    } else if (isInserting) {
      context.missing(_importanceMeta);
    }
    if (data.containsKey('deadline_at')) {
      context.handle(
        _deadlineAtMeta,
        deadlineAt.isAcceptableOrUnknown(data['deadline_at']!, _deadlineAtMeta),
      );
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_tagsJsonMeta);
    }
    if (data.containsKey('terminal_at')) {
      context.handle(
        _terminalAtMeta,
        terminalAt.isAcceptableOrUnknown(data['terminal_at']!, _terminalAtMeta),
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
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Task map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Task(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      ),
      userNotes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_notes'],
      ),
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      blockedReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}blocked_reason'],
      ),
      importance: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}importance'],
      )!,
      deadlineAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deadline_at'],
      ),
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      )!,
      terminalAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}terminal_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $TasksTable createAlias(String alias) {
    return $TasksTable(attachedDatabase, alias);
  }
}

class Task extends DataClass implements Insertable<Task> {
  final String id;
  final String accountId;
  final String title;
  final String? description;
  final String? userNotes;
  final String state;
  final String? blockedReason;
  final String importance;
  final int? deadlineAt;
  final String tagsJson;
  final int? terminalAt;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  const Task({
    required this.id,
    required this.accountId,
    required this.title,
    this.description,
    this.userNotes,
    required this.state,
    this.blockedReason,
    required this.importance,
    this.deadlineAt,
    required this.tagsJson,
    this.terminalAt,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || description != null) {
      map['description'] = Variable<String>(description);
    }
    if (!nullToAbsent || userNotes != null) {
      map['user_notes'] = Variable<String>(userNotes);
    }
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || blockedReason != null) {
      map['blocked_reason'] = Variable<String>(blockedReason);
    }
    map['importance'] = Variable<String>(importance);
    if (!nullToAbsent || deadlineAt != null) {
      map['deadline_at'] = Variable<int>(deadlineAt);
    }
    map['tags_json'] = Variable<String>(tagsJson);
    if (!nullToAbsent || terminalAt != null) {
      map['terminal_at'] = Variable<int>(terminalAt);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    return map;
  }

  TasksCompanion toCompanion(bool nullToAbsent) {
    return TasksCompanion(
      id: Value(id),
      accountId: Value(accountId),
      title: Value(title),
      description: description == null && nullToAbsent
          ? const Value.absent()
          : Value(description),
      userNotes: userNotes == null && nullToAbsent
          ? const Value.absent()
          : Value(userNotes),
      state: Value(state),
      blockedReason: blockedReason == null && nullToAbsent
          ? const Value.absent()
          : Value(blockedReason),
      importance: Value(importance),
      deadlineAt: deadlineAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deadlineAt),
      tagsJson: Value(tagsJson),
      terminalAt: terminalAt == null && nullToAbsent
          ? const Value.absent()
          : Value(terminalAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory Task.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Task(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      title: serializer.fromJson<String>(json['title']),
      description: serializer.fromJson<String?>(json['description']),
      userNotes: serializer.fromJson<String?>(json['userNotes']),
      state: serializer.fromJson<String>(json['state']),
      blockedReason: serializer.fromJson<String?>(json['blockedReason']),
      importance: serializer.fromJson<String>(json['importance']),
      deadlineAt: serializer.fromJson<int?>(json['deadlineAt']),
      tagsJson: serializer.fromJson<String>(json['tagsJson']),
      terminalAt: serializer.fromJson<int?>(json['terminalAt']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'title': serializer.toJson<String>(title),
      'description': serializer.toJson<String?>(description),
      'userNotes': serializer.toJson<String?>(userNotes),
      'state': serializer.toJson<String>(state),
      'blockedReason': serializer.toJson<String?>(blockedReason),
      'importance': serializer.toJson<String>(importance),
      'deadlineAt': serializer.toJson<int?>(deadlineAt),
      'tagsJson': serializer.toJson<String>(tagsJson),
      'terminalAt': serializer.toJson<int?>(terminalAt),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
    };
  }

  Task copyWith({
    String? id,
    String? accountId,
    String? title,
    Value<String?> description = const Value.absent(),
    Value<String?> userNotes = const Value.absent(),
    String? state,
    Value<String?> blockedReason = const Value.absent(),
    String? importance,
    Value<int?> deadlineAt = const Value.absent(),
    String? tagsJson,
    Value<int?> terminalAt = const Value.absent(),
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
  }) => Task(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    title: title ?? this.title,
    description: description.present ? description.value : this.description,
    userNotes: userNotes.present ? userNotes.value : this.userNotes,
    state: state ?? this.state,
    blockedReason: blockedReason.present
        ? blockedReason.value
        : this.blockedReason,
    importance: importance ?? this.importance,
    deadlineAt: deadlineAt.present ? deadlineAt.value : this.deadlineAt,
    tagsJson: tagsJson ?? this.tagsJson,
    terminalAt: terminalAt.present ? terminalAt.value : this.terminalAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  Task copyWithCompanion(TasksCompanion data) {
    return Task(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      title: data.title.present ? data.title.value : this.title,
      description: data.description.present
          ? data.description.value
          : this.description,
      userNotes: data.userNotes.present ? data.userNotes.value : this.userNotes,
      state: data.state.present ? data.state.value : this.state,
      blockedReason: data.blockedReason.present
          ? data.blockedReason.value
          : this.blockedReason,
      importance: data.importance.present
          ? data.importance.value
          : this.importance,
      deadlineAt: data.deadlineAt.present
          ? data.deadlineAt.value
          : this.deadlineAt,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
      terminalAt: data.terminalAt.present
          ? data.terminalAt.value
          : this.terminalAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Task(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('title: $title, ')
          ..write('description: $description, ')
          ..write('userNotes: $userNotes, ')
          ..write('state: $state, ')
          ..write('blockedReason: $blockedReason, ')
          ..write('importance: $importance, ')
          ..write('deadlineAt: $deadlineAt, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('terminalAt: $terminalAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    title,
    description,
    userNotes,
    state,
    blockedReason,
    importance,
    deadlineAt,
    tagsJson,
    terminalAt,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Task &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.title == this.title &&
          other.description == this.description &&
          other.userNotes == this.userNotes &&
          other.state == this.state &&
          other.blockedReason == this.blockedReason &&
          other.importance == this.importance &&
          other.deadlineAt == this.deadlineAt &&
          other.tagsJson == this.tagsJson &&
          other.terminalAt == this.terminalAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class TasksCompanion extends UpdateCompanion<Task> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> title;
  final Value<String?> description;
  final Value<String?> userNotes;
  final Value<String> state;
  final Value<String?> blockedReason;
  final Value<String> importance;
  final Value<int?> deadlineAt;
  final Value<String> tagsJson;
  final Value<int?> terminalAt;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<int> rowid;
  const TasksCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.title = const Value.absent(),
    this.description = const Value.absent(),
    this.userNotes = const Value.absent(),
    this.state = const Value.absent(),
    this.blockedReason = const Value.absent(),
    this.importance = const Value.absent(),
    this.deadlineAt = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.terminalAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TasksCompanion.insert({
    required String id,
    required String accountId,
    required String title,
    this.description = const Value.absent(),
    this.userNotes = const Value.absent(),
    required String state,
    this.blockedReason = const Value.absent(),
    required String importance,
    this.deadlineAt = const Value.absent(),
    required String tagsJson,
    this.terminalAt = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       title = Value(title),
       state = Value(state),
       importance = Value(importance),
       tagsJson = Value(tagsJson),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Task> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? title,
    Expression<String>? description,
    Expression<String>? userNotes,
    Expression<String>? state,
    Expression<String>? blockedReason,
    Expression<String>? importance,
    Expression<int>? deadlineAt,
    Expression<String>? tagsJson,
    Expression<int>? terminalAt,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (userNotes != null) 'user_notes': userNotes,
      if (state != null) 'state': state,
      if (blockedReason != null) 'blocked_reason': blockedReason,
      if (importance != null) 'importance': importance,
      if (deadlineAt != null) 'deadline_at': deadlineAt,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (terminalAt != null) 'terminal_at': terminalAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TasksCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? title,
    Value<String?>? description,
    Value<String?>? userNotes,
    Value<String>? state,
    Value<String?>? blockedReason,
    Value<String>? importance,
    Value<int?>? deadlineAt,
    Value<String>? tagsJson,
    Value<int?>? terminalAt,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<int>? rowid,
  }) {
    return TasksCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      title: title ?? this.title,
      description: description ?? this.description,
      userNotes: userNotes ?? this.userNotes,
      state: state ?? this.state,
      blockedReason: blockedReason ?? this.blockedReason,
      importance: importance ?? this.importance,
      deadlineAt: deadlineAt ?? this.deadlineAt,
      tagsJson: tagsJson ?? this.tagsJson,
      terminalAt: terminalAt ?? this.terminalAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
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
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (userNotes.present) {
      map['user_notes'] = Variable<String>(userNotes.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (blockedReason.present) {
      map['blocked_reason'] = Variable<String>(blockedReason.value);
    }
    if (importance.present) {
      map['importance'] = Variable<String>(importance.value);
    }
    if (deadlineAt.present) {
      map['deadline_at'] = Variable<int>(deadlineAt.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (terminalAt.present) {
      map['terminal_at'] = Variable<int>(terminalAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TasksCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('title: $title, ')
          ..write('description: $description, ')
          ..write('userNotes: $userNotes, ')
          ..write('state: $state, ')
          ..write('blockedReason: $blockedReason, ')
          ..write('importance: $importance, ')
          ..write('deadlineAt: $deadlineAt, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('terminalAt: $terminalAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlanBlocksTable extends PlanBlocks
    with TableInfo<$PlanBlocksTable, PlanBlock> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlanBlocksTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  @override
  late final GeneratedColumn<String> taskId = GeneratedColumn<String>(
    'task_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES tasks (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _startAtMeta = const VerificationMeta(
    'startAt',
  );
  @override
  late final GeneratedColumn<int> startAt = GeneratedColumn<int>(
    'start_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endAtMeta = const VerificationMeta('endAt');
  @override
  late final GeneratedColumn<int> endAt = GeneratedColumn<int>(
    'end_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reviewStateMeta = const VerificationMeta(
    'reviewState',
  );
  @override
  late final GeneratedColumn<String> reviewState = GeneratedColumn<String>(
    'review_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reviewNoteMeta = const VerificationMeta(
    'reviewNote',
  );
  @override
  late final GeneratedColumn<String> reviewNote = GeneratedColumn<String>(
    'review_note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reviewedAtMeta = const VerificationMeta(
    'reviewedAt',
  );
  @override
  late final GeneratedColumn<int> reviewedAt = GeneratedColumn<int>(
    'reviewed_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _replacementPlanBlockIdMeta =
      const VerificationMeta('replacementPlanBlockId');
  @override
  late final GeneratedColumn<String> replacementPlanBlockId =
      GeneratedColumn<String>(
        'replacement_plan_block_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
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
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    taskId,
    startAt,
    endAt,
    reviewState,
    reviewNote,
    reviewedAt,
    replacementPlanBlockId,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'plan_blocks';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlanBlock> instance, {
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
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('start_at')) {
      context.handle(
        _startAtMeta,
        startAt.isAcceptableOrUnknown(data['start_at']!, _startAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startAtMeta);
    }
    if (data.containsKey('end_at')) {
      context.handle(
        _endAtMeta,
        endAt.isAcceptableOrUnknown(data['end_at']!, _endAtMeta),
      );
    } else if (isInserting) {
      context.missing(_endAtMeta);
    }
    if (data.containsKey('review_state')) {
      context.handle(
        _reviewStateMeta,
        reviewState.isAcceptableOrUnknown(
          data['review_state']!,
          _reviewStateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_reviewStateMeta);
    }
    if (data.containsKey('review_note')) {
      context.handle(
        _reviewNoteMeta,
        reviewNote.isAcceptableOrUnknown(data['review_note']!, _reviewNoteMeta),
      );
    }
    if (data.containsKey('reviewed_at')) {
      context.handle(
        _reviewedAtMeta,
        reviewedAt.isAcceptableOrUnknown(data['reviewed_at']!, _reviewedAtMeta),
      );
    }
    if (data.containsKey('replacement_plan_block_id')) {
      context.handle(
        _replacementPlanBlockIdMeta,
        replacementPlanBlockId.isAcceptableOrUnknown(
          data['replacement_plan_block_id']!,
          _replacementPlanBlockIdMeta,
        ),
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
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlanBlock map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlanBlock(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_id'],
      )!,
      startAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_at'],
      )!,
      endAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}end_at'],
      )!,
      reviewState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}review_state'],
      )!,
      reviewNote: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}review_note'],
      ),
      reviewedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reviewed_at'],
      ),
      replacementPlanBlockId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}replacement_plan_block_id'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $PlanBlocksTable createAlias(String alias) {
    return $PlanBlocksTable(attachedDatabase, alias);
  }
}

class PlanBlock extends DataClass implements Insertable<PlanBlock> {
  final String id;
  final String accountId;
  final String taskId;
  final int startAt;
  final int endAt;
  final String reviewState;
  final String? reviewNote;
  final int? reviewedAt;
  final String? replacementPlanBlockId;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  const PlanBlock({
    required this.id,
    required this.accountId,
    required this.taskId,
    required this.startAt,
    required this.endAt,
    required this.reviewState,
    this.reviewNote,
    this.reviewedAt,
    this.replacementPlanBlockId,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['task_id'] = Variable<String>(taskId);
    map['start_at'] = Variable<int>(startAt);
    map['end_at'] = Variable<int>(endAt);
    map['review_state'] = Variable<String>(reviewState);
    if (!nullToAbsent || reviewNote != null) {
      map['review_note'] = Variable<String>(reviewNote);
    }
    if (!nullToAbsent || reviewedAt != null) {
      map['reviewed_at'] = Variable<int>(reviewedAt);
    }
    if (!nullToAbsent || replacementPlanBlockId != null) {
      map['replacement_plan_block_id'] = Variable<String>(
        replacementPlanBlockId,
      );
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    return map;
  }

  PlanBlocksCompanion toCompanion(bool nullToAbsent) {
    return PlanBlocksCompanion(
      id: Value(id),
      accountId: Value(accountId),
      taskId: Value(taskId),
      startAt: Value(startAt),
      endAt: Value(endAt),
      reviewState: Value(reviewState),
      reviewNote: reviewNote == null && nullToAbsent
          ? const Value.absent()
          : Value(reviewNote),
      reviewedAt: reviewedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(reviewedAt),
      replacementPlanBlockId: replacementPlanBlockId == null && nullToAbsent
          ? const Value.absent()
          : Value(replacementPlanBlockId),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory PlanBlock.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlanBlock(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      taskId: serializer.fromJson<String>(json['taskId']),
      startAt: serializer.fromJson<int>(json['startAt']),
      endAt: serializer.fromJson<int>(json['endAt']),
      reviewState: serializer.fromJson<String>(json['reviewState']),
      reviewNote: serializer.fromJson<String?>(json['reviewNote']),
      reviewedAt: serializer.fromJson<int?>(json['reviewedAt']),
      replacementPlanBlockId: serializer.fromJson<String?>(
        json['replacementPlanBlockId'],
      ),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'taskId': serializer.toJson<String>(taskId),
      'startAt': serializer.toJson<int>(startAt),
      'endAt': serializer.toJson<int>(endAt),
      'reviewState': serializer.toJson<String>(reviewState),
      'reviewNote': serializer.toJson<String?>(reviewNote),
      'reviewedAt': serializer.toJson<int?>(reviewedAt),
      'replacementPlanBlockId': serializer.toJson<String?>(
        replacementPlanBlockId,
      ),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
    };
  }

  PlanBlock copyWith({
    String? id,
    String? accountId,
    String? taskId,
    int? startAt,
    int? endAt,
    String? reviewState,
    Value<String?> reviewNote = const Value.absent(),
    Value<int?> reviewedAt = const Value.absent(),
    Value<String?> replacementPlanBlockId = const Value.absent(),
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
  }) => PlanBlock(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    taskId: taskId ?? this.taskId,
    startAt: startAt ?? this.startAt,
    endAt: endAt ?? this.endAt,
    reviewState: reviewState ?? this.reviewState,
    reviewNote: reviewNote.present ? reviewNote.value : this.reviewNote,
    reviewedAt: reviewedAt.present ? reviewedAt.value : this.reviewedAt,
    replacementPlanBlockId: replacementPlanBlockId.present
        ? replacementPlanBlockId.value
        : this.replacementPlanBlockId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  PlanBlock copyWithCompanion(PlanBlocksCompanion data) {
    return PlanBlock(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      startAt: data.startAt.present ? data.startAt.value : this.startAt,
      endAt: data.endAt.present ? data.endAt.value : this.endAt,
      reviewState: data.reviewState.present
          ? data.reviewState.value
          : this.reviewState,
      reviewNote: data.reviewNote.present
          ? data.reviewNote.value
          : this.reviewNote,
      reviewedAt: data.reviewedAt.present
          ? data.reviewedAt.value
          : this.reviewedAt,
      replacementPlanBlockId: data.replacementPlanBlockId.present
          ? data.replacementPlanBlockId.value
          : this.replacementPlanBlockId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlanBlock(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('taskId: $taskId, ')
          ..write('startAt: $startAt, ')
          ..write('endAt: $endAt, ')
          ..write('reviewState: $reviewState, ')
          ..write('reviewNote: $reviewNote, ')
          ..write('reviewedAt: $reviewedAt, ')
          ..write('replacementPlanBlockId: $replacementPlanBlockId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    taskId,
    startAt,
    endAt,
    reviewState,
    reviewNote,
    reviewedAt,
    replacementPlanBlockId,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlanBlock &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.taskId == this.taskId &&
          other.startAt == this.startAt &&
          other.endAt == this.endAt &&
          other.reviewState == this.reviewState &&
          other.reviewNote == this.reviewNote &&
          other.reviewedAt == this.reviewedAt &&
          other.replacementPlanBlockId == this.replacementPlanBlockId &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class PlanBlocksCompanion extends UpdateCompanion<PlanBlock> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> taskId;
  final Value<int> startAt;
  final Value<int> endAt;
  final Value<String> reviewState;
  final Value<String?> reviewNote;
  final Value<int?> reviewedAt;
  final Value<String?> replacementPlanBlockId;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<int> rowid;
  const PlanBlocksCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.taskId = const Value.absent(),
    this.startAt = const Value.absent(),
    this.endAt = const Value.absent(),
    this.reviewState = const Value.absent(),
    this.reviewNote = const Value.absent(),
    this.reviewedAt = const Value.absent(),
    this.replacementPlanBlockId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlanBlocksCompanion.insert({
    required String id,
    required String accountId,
    required String taskId,
    required int startAt,
    required int endAt,
    required String reviewState,
    this.reviewNote = const Value.absent(),
    this.reviewedAt = const Value.absent(),
    this.replacementPlanBlockId = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       taskId = Value(taskId),
       startAt = Value(startAt),
       endAt = Value(endAt),
       reviewState = Value(reviewState),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<PlanBlock> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? taskId,
    Expression<int>? startAt,
    Expression<int>? endAt,
    Expression<String>? reviewState,
    Expression<String>? reviewNote,
    Expression<int>? reviewedAt,
    Expression<String>? replacementPlanBlockId,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (taskId != null) 'task_id': taskId,
      if (startAt != null) 'start_at': startAt,
      if (endAt != null) 'end_at': endAt,
      if (reviewState != null) 'review_state': reviewState,
      if (reviewNote != null) 'review_note': reviewNote,
      if (reviewedAt != null) 'reviewed_at': reviewedAt,
      if (replacementPlanBlockId != null)
        'replacement_plan_block_id': replacementPlanBlockId,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlanBlocksCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? taskId,
    Value<int>? startAt,
    Value<int>? endAt,
    Value<String>? reviewState,
    Value<String?>? reviewNote,
    Value<int?>? reviewedAt,
    Value<String?>? replacementPlanBlockId,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<int>? rowid,
  }) {
    return PlanBlocksCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      taskId: taskId ?? this.taskId,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      reviewState: reviewState ?? this.reviewState,
      reviewNote: reviewNote ?? this.reviewNote,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      replacementPlanBlockId:
          replacementPlanBlockId ?? this.replacementPlanBlockId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
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
    if (taskId.present) {
      map['task_id'] = Variable<String>(taskId.value);
    }
    if (startAt.present) {
      map['start_at'] = Variable<int>(startAt.value);
    }
    if (endAt.present) {
      map['end_at'] = Variable<int>(endAt.value);
    }
    if (reviewState.present) {
      map['review_state'] = Variable<String>(reviewState.value);
    }
    if (reviewNote.present) {
      map['review_note'] = Variable<String>(reviewNote.value);
    }
    if (reviewedAt.present) {
      map['reviewed_at'] = Variable<int>(reviewedAt.value);
    }
    if (replacementPlanBlockId.present) {
      map['replacement_plan_block_id'] = Variable<String>(
        replacementPlanBlockId.value,
      );
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlanBlocksCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('taskId: $taskId, ')
          ..write('startAt: $startAt, ')
          ..write('endAt: $endAt, ')
          ..write('reviewState: $reviewState, ')
          ..write('reviewNote: $reviewNote, ')
          ..write('reviewedAt: $reviewedAt, ')
          ..write('replacementPlanBlockId: $replacementPlanBlockId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TaskEventLinksTable extends TaskEventLinks
    with TableInfo<$TaskEventLinksTable, TaskEventLink> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskEventLinksTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  @override
  late final GeneratedColumn<String> taskId = GeneratedColumn<String>(
    'task_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES tasks (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _eventIdMeta = const VerificationMeta(
    'eventId',
  );
  @override
  late final GeneratedColumn<String> eventId = GeneratedColumn<String>(
    'event_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES calendar_events (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _relationTypeMeta = const VerificationMeta(
    'relationType',
  );
  @override
  late final GeneratedColumn<String> relationType = GeneratedColumn<String>(
    'relation_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    taskId,
    eventId,
    relationType,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_event_links';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskEventLink> instance, {
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
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('event_id')) {
      context.handle(
        _eventIdMeta,
        eventId.isAcceptableOrUnknown(data['event_id']!, _eventIdMeta),
      );
    } else if (isInserting) {
      context.missing(_eventIdMeta);
    }
    if (data.containsKey('relation_type')) {
      context.handle(
        _relationTypeMeta,
        relationType.isAcceptableOrUnknown(
          data['relation_type']!,
          _relationTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_relationTypeMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, taskId, eventId};
  @override
  TaskEventLink map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskEventLink(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_id'],
      )!,
      eventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_id'],
      )!,
      relationType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}relation_type'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $TaskEventLinksTable createAlias(String alias) {
    return $TaskEventLinksTable(attachedDatabase, alias);
  }
}

class TaskEventLink extends DataClass implements Insertable<TaskEventLink> {
  final String accountId;
  final String taskId;
  final String eventId;
  final String relationType;
  final int createdAt;
  const TaskEventLink({
    required this.accountId,
    required this.taskId,
    required this.eventId,
    required this.relationType,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['task_id'] = Variable<String>(taskId);
    map['event_id'] = Variable<String>(eventId);
    map['relation_type'] = Variable<String>(relationType);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  TaskEventLinksCompanion toCompanion(bool nullToAbsent) {
    return TaskEventLinksCompanion(
      accountId: Value(accountId),
      taskId: Value(taskId),
      eventId: Value(eventId),
      relationType: Value(relationType),
      createdAt: Value(createdAt),
    );
  }

  factory TaskEventLink.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskEventLink(
      accountId: serializer.fromJson<String>(json['accountId']),
      taskId: serializer.fromJson<String>(json['taskId']),
      eventId: serializer.fromJson<String>(json['eventId']),
      relationType: serializer.fromJson<String>(json['relationType']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'taskId': serializer.toJson<String>(taskId),
      'eventId': serializer.toJson<String>(eventId),
      'relationType': serializer.toJson<String>(relationType),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  TaskEventLink copyWith({
    String? accountId,
    String? taskId,
    String? eventId,
    String? relationType,
    int? createdAt,
  }) => TaskEventLink(
    accountId: accountId ?? this.accountId,
    taskId: taskId ?? this.taskId,
    eventId: eventId ?? this.eventId,
    relationType: relationType ?? this.relationType,
    createdAt: createdAt ?? this.createdAt,
  );
  TaskEventLink copyWithCompanion(TaskEventLinksCompanion data) {
    return TaskEventLink(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      eventId: data.eventId.present ? data.eventId.value : this.eventId,
      relationType: data.relationType.present
          ? data.relationType.value
          : this.relationType,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskEventLink(')
          ..write('accountId: $accountId, ')
          ..write('taskId: $taskId, ')
          ..write('eventId: $eventId, ')
          ..write('relationType: $relationType, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(accountId, taskId, eventId, relationType, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskEventLink &&
          other.accountId == this.accountId &&
          other.taskId == this.taskId &&
          other.eventId == this.eventId &&
          other.relationType == this.relationType &&
          other.createdAt == this.createdAt);
}

class TaskEventLinksCompanion extends UpdateCompanion<TaskEventLink> {
  final Value<String> accountId;
  final Value<String> taskId;
  final Value<String> eventId;
  final Value<String> relationType;
  final Value<int> createdAt;
  final Value<int> rowid;
  const TaskEventLinksCompanion({
    this.accountId = const Value.absent(),
    this.taskId = const Value.absent(),
    this.eventId = const Value.absent(),
    this.relationType = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TaskEventLinksCompanion.insert({
    required String accountId,
    required String taskId,
    required String eventId,
    required String relationType,
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       taskId = Value(taskId),
       eventId = Value(eventId),
       relationType = Value(relationType),
       createdAt = Value(createdAt);
  static Insertable<TaskEventLink> custom({
    Expression<String>? accountId,
    Expression<String>? taskId,
    Expression<String>? eventId,
    Expression<String>? relationType,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (taskId != null) 'task_id': taskId,
      if (eventId != null) 'event_id': eventId,
      if (relationType != null) 'relation_type': relationType,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TaskEventLinksCompanion copyWith({
    Value<String>? accountId,
    Value<String>? taskId,
    Value<String>? eventId,
    Value<String>? relationType,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return TaskEventLinksCompanion(
      accountId: accountId ?? this.accountId,
      taskId: taskId ?? this.taskId,
      eventId: eventId ?? this.eventId,
      relationType: relationType ?? this.relationType,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (taskId.present) {
      map['task_id'] = Variable<String>(taskId.value);
    }
    if (eventId.present) {
      map['event_id'] = Variable<String>(eventId.value);
    }
    if (relationType.present) {
      map['relation_type'] = Variable<String>(relationType.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskEventLinksCompanion(')
          ..write('accountId: $accountId, ')
          ..write('taskId: $taskId, ')
          ..write('eventId: $eventId, ')
          ..write('relationType: $relationType, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScheduleRelationsTable extends ScheduleRelations
    with TableInfo<$ScheduleRelationsTable, ScheduleRelation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScheduleRelationsTable(this.attachedDatabase, [this._alias]);
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
    requiredDuringInsert: false,
    defaultValue: const Constant('user'),
  );
  static const VerificationMeta _externalIdMeta = const VerificationMeta(
    'externalId',
  );
  @override
  late final GeneratedColumn<String> externalId = GeneratedColumn<String>(
    'external_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _relationTypeMeta = const VerificationMeta(
    'relationType',
  );
  @override
  late final GeneratedColumn<String> relationType = GeneratedColumn<String>(
    'relation_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('conflict'),
  );
  static const VerificationMeta _primaryEntityTypeMeta = const VerificationMeta(
    'primaryEntityType',
  );
  @override
  late final GeneratedColumn<String> primaryEntityType =
      GeneratedColumn<String>(
        'primary_entity_type',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _primaryEntityIdMeta = const VerificationMeta(
    'primaryEntityId',
  );
  @override
  late final GeneratedColumn<String> primaryEntityId = GeneratedColumn<String>(
    'primary_entity_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _relatedEntityTypeMeta = const VerificationMeta(
    'relatedEntityType',
  );
  @override
  late final GeneratedColumn<String> relatedEntityType =
      GeneratedColumn<String>(
        'related_entity_type',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _relatedEntityIdMeta = const VerificationMeta(
    'relatedEntityId',
  );
  @override
  late final GeneratedColumn<String> relatedEntityId = GeneratedColumn<String>(
    'related_entity_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _leftKindMeta = const VerificationMeta(
    'leftKind',
  );
  @override
  late final GeneratedColumn<String> leftKind = GeneratedColumn<String>(
    'left_kind',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _leftIdMeta = const VerificationMeta('leftId');
  @override
  late final GeneratedColumn<String> leftId = GeneratedColumn<String>(
    'left_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rightKindMeta = const VerificationMeta(
    'rightKind',
  );
  @override
  late final GeneratedColumn<String> rightKind = GeneratedColumn<String>(
    'right_kind',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rightIdMeta = const VerificationMeta(
    'rightId',
  );
  @override
  late final GeneratedColumn<String> rightId = GeneratedColumn<String>(
    'right_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _leftEventIdMeta = const VerificationMeta(
    'leftEventId',
  );
  @override
  late final GeneratedColumn<String> leftEventId = GeneratedColumn<String>(
    'left_event_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES calendar_events (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _leftPlanBlockIdMeta = const VerificationMeta(
    'leftPlanBlockId',
  );
  @override
  late final GeneratedColumn<String> leftPlanBlockId = GeneratedColumn<String>(
    'left_plan_block_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES plan_blocks (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _rightEventIdMeta = const VerificationMeta(
    'rightEventId',
  );
  @override
  late final GeneratedColumn<String> rightEventId = GeneratedColumn<String>(
    'right_event_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES calendar_events (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _rightPlanBlockIdMeta = const VerificationMeta(
    'rightPlanBlockId',
  );
  @override
  late final GeneratedColumn<String> rightPlanBlockId = GeneratedColumn<String>(
    'right_plan_block_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES plan_blocks (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _conflictStateMeta = const VerificationMeta(
    'conflictState',
  );
  @override
  late final GeneratedColumn<String> conflictState = GeneratedColumn<String>(
    'conflict_state',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reasonMeta = const VerificationMeta('reason');
  @override
  late final GeneratedColumn<String> reason = GeneratedColumn<String>(
    'reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
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
    accountId,
    source,
    externalId,
    relationType,
    primaryEntityType,
    primaryEntityId,
    relatedEntityType,
    relatedEntityId,
    leftKind,
    leftId,
    rightKind,
    rightId,
    leftEventId,
    leftPlanBlockId,
    rightEventId,
    rightPlanBlockId,
    conflictState,
    reason,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'schedule_relations';
  @override
  VerificationContext validateIntegrity(
    Insertable<ScheduleRelation> instance, {
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
    }
    if (data.containsKey('external_id')) {
      context.handle(
        _externalIdMeta,
        externalId.isAcceptableOrUnknown(data['external_id']!, _externalIdMeta),
      );
    }
    if (data.containsKey('relation_type')) {
      context.handle(
        _relationTypeMeta,
        relationType.isAcceptableOrUnknown(
          data['relation_type']!,
          _relationTypeMeta,
        ),
      );
    }
    if (data.containsKey('primary_entity_type')) {
      context.handle(
        _primaryEntityTypeMeta,
        primaryEntityType.isAcceptableOrUnknown(
          data['primary_entity_type']!,
          _primaryEntityTypeMeta,
        ),
      );
    }
    if (data.containsKey('primary_entity_id')) {
      context.handle(
        _primaryEntityIdMeta,
        primaryEntityId.isAcceptableOrUnknown(
          data['primary_entity_id']!,
          _primaryEntityIdMeta,
        ),
      );
    }
    if (data.containsKey('related_entity_type')) {
      context.handle(
        _relatedEntityTypeMeta,
        relatedEntityType.isAcceptableOrUnknown(
          data['related_entity_type']!,
          _relatedEntityTypeMeta,
        ),
      );
    }
    if (data.containsKey('related_entity_id')) {
      context.handle(
        _relatedEntityIdMeta,
        relatedEntityId.isAcceptableOrUnknown(
          data['related_entity_id']!,
          _relatedEntityIdMeta,
        ),
      );
    }
    if (data.containsKey('left_kind')) {
      context.handle(
        _leftKindMeta,
        leftKind.isAcceptableOrUnknown(data['left_kind']!, _leftKindMeta),
      );
    }
    if (data.containsKey('left_id')) {
      context.handle(
        _leftIdMeta,
        leftId.isAcceptableOrUnknown(data['left_id']!, _leftIdMeta),
      );
    }
    if (data.containsKey('right_kind')) {
      context.handle(
        _rightKindMeta,
        rightKind.isAcceptableOrUnknown(data['right_kind']!, _rightKindMeta),
      );
    }
    if (data.containsKey('right_id')) {
      context.handle(
        _rightIdMeta,
        rightId.isAcceptableOrUnknown(data['right_id']!, _rightIdMeta),
      );
    }
    if (data.containsKey('left_event_id')) {
      context.handle(
        _leftEventIdMeta,
        leftEventId.isAcceptableOrUnknown(
          data['left_event_id']!,
          _leftEventIdMeta,
        ),
      );
    }
    if (data.containsKey('left_plan_block_id')) {
      context.handle(
        _leftPlanBlockIdMeta,
        leftPlanBlockId.isAcceptableOrUnknown(
          data['left_plan_block_id']!,
          _leftPlanBlockIdMeta,
        ),
      );
    }
    if (data.containsKey('right_event_id')) {
      context.handle(
        _rightEventIdMeta,
        rightEventId.isAcceptableOrUnknown(
          data['right_event_id']!,
          _rightEventIdMeta,
        ),
      );
    }
    if (data.containsKey('right_plan_block_id')) {
      context.handle(
        _rightPlanBlockIdMeta,
        rightPlanBlockId.isAcceptableOrUnknown(
          data['right_plan_block_id']!,
          _rightPlanBlockIdMeta,
        ),
      );
    }
    if (data.containsKey('conflict_state')) {
      context.handle(
        _conflictStateMeta,
        conflictState.isAcceptableOrUnknown(
          data['conflict_state']!,
          _conflictStateMeta,
        ),
      );
    }
    if (data.containsKey('reason')) {
      context.handle(
        _reasonMeta,
        reason.isAcceptableOrUnknown(data['reason']!, _reasonMeta),
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
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, leftKind, leftId, rightKind, rightId},
    {accountId, source, externalId},
  ];
  @override
  ScheduleRelation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ScheduleRelation(
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
      externalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}external_id'],
      ),
      relationType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}relation_type'],
      )!,
      primaryEntityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}primary_entity_type'],
      ),
      primaryEntityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}primary_entity_id'],
      ),
      relatedEntityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}related_entity_type'],
      ),
      relatedEntityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}related_entity_id'],
      ),
      leftKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}left_kind'],
      ),
      leftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}left_id'],
      ),
      rightKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}right_kind'],
      ),
      rightId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}right_id'],
      ),
      leftEventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}left_event_id'],
      ),
      leftPlanBlockId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}left_plan_block_id'],
      ),
      rightEventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}right_event_id'],
      ),
      rightPlanBlockId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}right_plan_block_id'],
      ),
      conflictState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conflict_state'],
      ),
      reason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reason'],
      ),
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
  $ScheduleRelationsTable createAlias(String alias) {
    return $ScheduleRelationsTable(attachedDatabase, alias);
  }
}

class ScheduleRelation extends DataClass
    implements Insertable<ScheduleRelation> {
  final String id;
  final String accountId;
  final String source;
  final String? externalId;
  final String relationType;
  final String? primaryEntityType;
  final String? primaryEntityId;
  final String? relatedEntityType;
  final String? relatedEntityId;
  final String? leftKind;
  final String? leftId;
  final String? rightKind;
  final String? rightId;
  final String? leftEventId;
  final String? leftPlanBlockId;
  final String? rightEventId;
  final String? rightPlanBlockId;
  final String? conflictState;
  final String? reason;
  final int createdAt;
  final int updatedAt;
  const ScheduleRelation({
    required this.id,
    required this.accountId,
    required this.source,
    this.externalId,
    required this.relationType,
    this.primaryEntityType,
    this.primaryEntityId,
    this.relatedEntityType,
    this.relatedEntityId,
    this.leftKind,
    this.leftId,
    this.rightKind,
    this.rightId,
    this.leftEventId,
    this.leftPlanBlockId,
    this.rightEventId,
    this.rightPlanBlockId,
    this.conflictState,
    this.reason,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || externalId != null) {
      map['external_id'] = Variable<String>(externalId);
    }
    map['relation_type'] = Variable<String>(relationType);
    if (!nullToAbsent || primaryEntityType != null) {
      map['primary_entity_type'] = Variable<String>(primaryEntityType);
    }
    if (!nullToAbsent || primaryEntityId != null) {
      map['primary_entity_id'] = Variable<String>(primaryEntityId);
    }
    if (!nullToAbsent || relatedEntityType != null) {
      map['related_entity_type'] = Variable<String>(relatedEntityType);
    }
    if (!nullToAbsent || relatedEntityId != null) {
      map['related_entity_id'] = Variable<String>(relatedEntityId);
    }
    if (!nullToAbsent || leftKind != null) {
      map['left_kind'] = Variable<String>(leftKind);
    }
    if (!nullToAbsent || leftId != null) {
      map['left_id'] = Variable<String>(leftId);
    }
    if (!nullToAbsent || rightKind != null) {
      map['right_kind'] = Variable<String>(rightKind);
    }
    if (!nullToAbsent || rightId != null) {
      map['right_id'] = Variable<String>(rightId);
    }
    if (!nullToAbsent || leftEventId != null) {
      map['left_event_id'] = Variable<String>(leftEventId);
    }
    if (!nullToAbsent || leftPlanBlockId != null) {
      map['left_plan_block_id'] = Variable<String>(leftPlanBlockId);
    }
    if (!nullToAbsent || rightEventId != null) {
      map['right_event_id'] = Variable<String>(rightEventId);
    }
    if (!nullToAbsent || rightPlanBlockId != null) {
      map['right_plan_block_id'] = Variable<String>(rightPlanBlockId);
    }
    if (!nullToAbsent || conflictState != null) {
      map['conflict_state'] = Variable<String>(conflictState);
    }
    if (!nullToAbsent || reason != null) {
      map['reason'] = Variable<String>(reason);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  ScheduleRelationsCompanion toCompanion(bool nullToAbsent) {
    return ScheduleRelationsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      source: Value(source),
      externalId: externalId == null && nullToAbsent
          ? const Value.absent()
          : Value(externalId),
      relationType: Value(relationType),
      primaryEntityType: primaryEntityType == null && nullToAbsent
          ? const Value.absent()
          : Value(primaryEntityType),
      primaryEntityId: primaryEntityId == null && nullToAbsent
          ? const Value.absent()
          : Value(primaryEntityId),
      relatedEntityType: relatedEntityType == null && nullToAbsent
          ? const Value.absent()
          : Value(relatedEntityType),
      relatedEntityId: relatedEntityId == null && nullToAbsent
          ? const Value.absent()
          : Value(relatedEntityId),
      leftKind: leftKind == null && nullToAbsent
          ? const Value.absent()
          : Value(leftKind),
      leftId: leftId == null && nullToAbsent
          ? const Value.absent()
          : Value(leftId),
      rightKind: rightKind == null && nullToAbsent
          ? const Value.absent()
          : Value(rightKind),
      rightId: rightId == null && nullToAbsent
          ? const Value.absent()
          : Value(rightId),
      leftEventId: leftEventId == null && nullToAbsent
          ? const Value.absent()
          : Value(leftEventId),
      leftPlanBlockId: leftPlanBlockId == null && nullToAbsent
          ? const Value.absent()
          : Value(leftPlanBlockId),
      rightEventId: rightEventId == null && nullToAbsent
          ? const Value.absent()
          : Value(rightEventId),
      rightPlanBlockId: rightPlanBlockId == null && nullToAbsent
          ? const Value.absent()
          : Value(rightPlanBlockId),
      conflictState: conflictState == null && nullToAbsent
          ? const Value.absent()
          : Value(conflictState),
      reason: reason == null && nullToAbsent
          ? const Value.absent()
          : Value(reason),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ScheduleRelation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ScheduleRelation(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      source: serializer.fromJson<String>(json['source']),
      externalId: serializer.fromJson<String?>(json['externalId']),
      relationType: serializer.fromJson<String>(json['relationType']),
      primaryEntityType: serializer.fromJson<String?>(
        json['primaryEntityType'],
      ),
      primaryEntityId: serializer.fromJson<String?>(json['primaryEntityId']),
      relatedEntityType: serializer.fromJson<String?>(
        json['relatedEntityType'],
      ),
      relatedEntityId: serializer.fromJson<String?>(json['relatedEntityId']),
      leftKind: serializer.fromJson<String?>(json['leftKind']),
      leftId: serializer.fromJson<String?>(json['leftId']),
      rightKind: serializer.fromJson<String?>(json['rightKind']),
      rightId: serializer.fromJson<String?>(json['rightId']),
      leftEventId: serializer.fromJson<String?>(json['leftEventId']),
      leftPlanBlockId: serializer.fromJson<String?>(json['leftPlanBlockId']),
      rightEventId: serializer.fromJson<String?>(json['rightEventId']),
      rightPlanBlockId: serializer.fromJson<String?>(json['rightPlanBlockId']),
      conflictState: serializer.fromJson<String?>(json['conflictState']),
      reason: serializer.fromJson<String?>(json['reason']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
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
      'externalId': serializer.toJson<String?>(externalId),
      'relationType': serializer.toJson<String>(relationType),
      'primaryEntityType': serializer.toJson<String?>(primaryEntityType),
      'primaryEntityId': serializer.toJson<String?>(primaryEntityId),
      'relatedEntityType': serializer.toJson<String?>(relatedEntityType),
      'relatedEntityId': serializer.toJson<String?>(relatedEntityId),
      'leftKind': serializer.toJson<String?>(leftKind),
      'leftId': serializer.toJson<String?>(leftId),
      'rightKind': serializer.toJson<String?>(rightKind),
      'rightId': serializer.toJson<String?>(rightId),
      'leftEventId': serializer.toJson<String?>(leftEventId),
      'leftPlanBlockId': serializer.toJson<String?>(leftPlanBlockId),
      'rightEventId': serializer.toJson<String?>(rightEventId),
      'rightPlanBlockId': serializer.toJson<String?>(rightPlanBlockId),
      'conflictState': serializer.toJson<String?>(conflictState),
      'reason': serializer.toJson<String?>(reason),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  ScheduleRelation copyWith({
    String? id,
    String? accountId,
    String? source,
    Value<String?> externalId = const Value.absent(),
    String? relationType,
    Value<String?> primaryEntityType = const Value.absent(),
    Value<String?> primaryEntityId = const Value.absent(),
    Value<String?> relatedEntityType = const Value.absent(),
    Value<String?> relatedEntityId = const Value.absent(),
    Value<String?> leftKind = const Value.absent(),
    Value<String?> leftId = const Value.absent(),
    Value<String?> rightKind = const Value.absent(),
    Value<String?> rightId = const Value.absent(),
    Value<String?> leftEventId = const Value.absent(),
    Value<String?> leftPlanBlockId = const Value.absent(),
    Value<String?> rightEventId = const Value.absent(),
    Value<String?> rightPlanBlockId = const Value.absent(),
    Value<String?> conflictState = const Value.absent(),
    Value<String?> reason = const Value.absent(),
    int? createdAt,
    int? updatedAt,
  }) => ScheduleRelation(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    source: source ?? this.source,
    externalId: externalId.present ? externalId.value : this.externalId,
    relationType: relationType ?? this.relationType,
    primaryEntityType: primaryEntityType.present
        ? primaryEntityType.value
        : this.primaryEntityType,
    primaryEntityId: primaryEntityId.present
        ? primaryEntityId.value
        : this.primaryEntityId,
    relatedEntityType: relatedEntityType.present
        ? relatedEntityType.value
        : this.relatedEntityType,
    relatedEntityId: relatedEntityId.present
        ? relatedEntityId.value
        : this.relatedEntityId,
    leftKind: leftKind.present ? leftKind.value : this.leftKind,
    leftId: leftId.present ? leftId.value : this.leftId,
    rightKind: rightKind.present ? rightKind.value : this.rightKind,
    rightId: rightId.present ? rightId.value : this.rightId,
    leftEventId: leftEventId.present ? leftEventId.value : this.leftEventId,
    leftPlanBlockId: leftPlanBlockId.present
        ? leftPlanBlockId.value
        : this.leftPlanBlockId,
    rightEventId: rightEventId.present ? rightEventId.value : this.rightEventId,
    rightPlanBlockId: rightPlanBlockId.present
        ? rightPlanBlockId.value
        : this.rightPlanBlockId,
    conflictState: conflictState.present
        ? conflictState.value
        : this.conflictState,
    reason: reason.present ? reason.value : this.reason,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ScheduleRelation copyWithCompanion(ScheduleRelationsCompanion data) {
    return ScheduleRelation(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      source: data.source.present ? data.source.value : this.source,
      externalId: data.externalId.present
          ? data.externalId.value
          : this.externalId,
      relationType: data.relationType.present
          ? data.relationType.value
          : this.relationType,
      primaryEntityType: data.primaryEntityType.present
          ? data.primaryEntityType.value
          : this.primaryEntityType,
      primaryEntityId: data.primaryEntityId.present
          ? data.primaryEntityId.value
          : this.primaryEntityId,
      relatedEntityType: data.relatedEntityType.present
          ? data.relatedEntityType.value
          : this.relatedEntityType,
      relatedEntityId: data.relatedEntityId.present
          ? data.relatedEntityId.value
          : this.relatedEntityId,
      leftKind: data.leftKind.present ? data.leftKind.value : this.leftKind,
      leftId: data.leftId.present ? data.leftId.value : this.leftId,
      rightKind: data.rightKind.present ? data.rightKind.value : this.rightKind,
      rightId: data.rightId.present ? data.rightId.value : this.rightId,
      leftEventId: data.leftEventId.present
          ? data.leftEventId.value
          : this.leftEventId,
      leftPlanBlockId: data.leftPlanBlockId.present
          ? data.leftPlanBlockId.value
          : this.leftPlanBlockId,
      rightEventId: data.rightEventId.present
          ? data.rightEventId.value
          : this.rightEventId,
      rightPlanBlockId: data.rightPlanBlockId.present
          ? data.rightPlanBlockId.value
          : this.rightPlanBlockId,
      conflictState: data.conflictState.present
          ? data.conflictState.value
          : this.conflictState,
      reason: data.reason.present ? data.reason.value : this.reason,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ScheduleRelation(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('externalId: $externalId, ')
          ..write('relationType: $relationType, ')
          ..write('primaryEntityType: $primaryEntityType, ')
          ..write('primaryEntityId: $primaryEntityId, ')
          ..write('relatedEntityType: $relatedEntityType, ')
          ..write('relatedEntityId: $relatedEntityId, ')
          ..write('leftKind: $leftKind, ')
          ..write('leftId: $leftId, ')
          ..write('rightKind: $rightKind, ')
          ..write('rightId: $rightId, ')
          ..write('leftEventId: $leftEventId, ')
          ..write('leftPlanBlockId: $leftPlanBlockId, ')
          ..write('rightEventId: $rightEventId, ')
          ..write('rightPlanBlockId: $rightPlanBlockId, ')
          ..write('conflictState: $conflictState, ')
          ..write('reason: $reason, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    accountId,
    source,
    externalId,
    relationType,
    primaryEntityType,
    primaryEntityId,
    relatedEntityType,
    relatedEntityId,
    leftKind,
    leftId,
    rightKind,
    rightId,
    leftEventId,
    leftPlanBlockId,
    rightEventId,
    rightPlanBlockId,
    conflictState,
    reason,
    createdAt,
    updatedAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScheduleRelation &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.source == this.source &&
          other.externalId == this.externalId &&
          other.relationType == this.relationType &&
          other.primaryEntityType == this.primaryEntityType &&
          other.primaryEntityId == this.primaryEntityId &&
          other.relatedEntityType == this.relatedEntityType &&
          other.relatedEntityId == this.relatedEntityId &&
          other.leftKind == this.leftKind &&
          other.leftId == this.leftId &&
          other.rightKind == this.rightKind &&
          other.rightId == this.rightId &&
          other.leftEventId == this.leftEventId &&
          other.leftPlanBlockId == this.leftPlanBlockId &&
          other.rightEventId == this.rightEventId &&
          other.rightPlanBlockId == this.rightPlanBlockId &&
          other.conflictState == this.conflictState &&
          other.reason == this.reason &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ScheduleRelationsCompanion extends UpdateCompanion<ScheduleRelation> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> source;
  final Value<String?> externalId;
  final Value<String> relationType;
  final Value<String?> primaryEntityType;
  final Value<String?> primaryEntityId;
  final Value<String?> relatedEntityType;
  final Value<String?> relatedEntityId;
  final Value<String?> leftKind;
  final Value<String?> leftId;
  final Value<String?> rightKind;
  final Value<String?> rightId;
  final Value<String?> leftEventId;
  final Value<String?> leftPlanBlockId;
  final Value<String?> rightEventId;
  final Value<String?> rightPlanBlockId;
  final Value<String?> conflictState;
  final Value<String?> reason;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const ScheduleRelationsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.source = const Value.absent(),
    this.externalId = const Value.absent(),
    this.relationType = const Value.absent(),
    this.primaryEntityType = const Value.absent(),
    this.primaryEntityId = const Value.absent(),
    this.relatedEntityType = const Value.absent(),
    this.relatedEntityId = const Value.absent(),
    this.leftKind = const Value.absent(),
    this.leftId = const Value.absent(),
    this.rightKind = const Value.absent(),
    this.rightId = const Value.absent(),
    this.leftEventId = const Value.absent(),
    this.leftPlanBlockId = const Value.absent(),
    this.rightEventId = const Value.absent(),
    this.rightPlanBlockId = const Value.absent(),
    this.conflictState = const Value.absent(),
    this.reason = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ScheduleRelationsCompanion.insert({
    required String id,
    required String accountId,
    this.source = const Value.absent(),
    this.externalId = const Value.absent(),
    this.relationType = const Value.absent(),
    this.primaryEntityType = const Value.absent(),
    this.primaryEntityId = const Value.absent(),
    this.relatedEntityType = const Value.absent(),
    this.relatedEntityId = const Value.absent(),
    this.leftKind = const Value.absent(),
    this.leftId = const Value.absent(),
    this.rightKind = const Value.absent(),
    this.rightId = const Value.absent(),
    this.leftEventId = const Value.absent(),
    this.leftPlanBlockId = const Value.absent(),
    this.rightEventId = const Value.absent(),
    this.rightPlanBlockId = const Value.absent(),
    this.conflictState = const Value.absent(),
    this.reason = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<ScheduleRelation> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? source,
    Expression<String>? externalId,
    Expression<String>? relationType,
    Expression<String>? primaryEntityType,
    Expression<String>? primaryEntityId,
    Expression<String>? relatedEntityType,
    Expression<String>? relatedEntityId,
    Expression<String>? leftKind,
    Expression<String>? leftId,
    Expression<String>? rightKind,
    Expression<String>? rightId,
    Expression<String>? leftEventId,
    Expression<String>? leftPlanBlockId,
    Expression<String>? rightEventId,
    Expression<String>? rightPlanBlockId,
    Expression<String>? conflictState,
    Expression<String>? reason,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (source != null) 'source': source,
      if (externalId != null) 'external_id': externalId,
      if (relationType != null) 'relation_type': relationType,
      if (primaryEntityType != null) 'primary_entity_type': primaryEntityType,
      if (primaryEntityId != null) 'primary_entity_id': primaryEntityId,
      if (relatedEntityType != null) 'related_entity_type': relatedEntityType,
      if (relatedEntityId != null) 'related_entity_id': relatedEntityId,
      if (leftKind != null) 'left_kind': leftKind,
      if (leftId != null) 'left_id': leftId,
      if (rightKind != null) 'right_kind': rightKind,
      if (rightId != null) 'right_id': rightId,
      if (leftEventId != null) 'left_event_id': leftEventId,
      if (leftPlanBlockId != null) 'left_plan_block_id': leftPlanBlockId,
      if (rightEventId != null) 'right_event_id': rightEventId,
      if (rightPlanBlockId != null) 'right_plan_block_id': rightPlanBlockId,
      if (conflictState != null) 'conflict_state': conflictState,
      if (reason != null) 'reason': reason,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ScheduleRelationsCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? source,
    Value<String?>? externalId,
    Value<String>? relationType,
    Value<String?>? primaryEntityType,
    Value<String?>? primaryEntityId,
    Value<String?>? relatedEntityType,
    Value<String?>? relatedEntityId,
    Value<String?>? leftKind,
    Value<String?>? leftId,
    Value<String?>? rightKind,
    Value<String?>? rightId,
    Value<String?>? leftEventId,
    Value<String?>? leftPlanBlockId,
    Value<String?>? rightEventId,
    Value<String?>? rightPlanBlockId,
    Value<String?>? conflictState,
    Value<String?>? reason,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return ScheduleRelationsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      source: source ?? this.source,
      externalId: externalId ?? this.externalId,
      relationType: relationType ?? this.relationType,
      primaryEntityType: primaryEntityType ?? this.primaryEntityType,
      primaryEntityId: primaryEntityId ?? this.primaryEntityId,
      relatedEntityType: relatedEntityType ?? this.relatedEntityType,
      relatedEntityId: relatedEntityId ?? this.relatedEntityId,
      leftKind: leftKind ?? this.leftKind,
      leftId: leftId ?? this.leftId,
      rightKind: rightKind ?? this.rightKind,
      rightId: rightId ?? this.rightId,
      leftEventId: leftEventId ?? this.leftEventId,
      leftPlanBlockId: leftPlanBlockId ?? this.leftPlanBlockId,
      rightEventId: rightEventId ?? this.rightEventId,
      rightPlanBlockId: rightPlanBlockId ?? this.rightPlanBlockId,
      conflictState: conflictState ?? this.conflictState,
      reason: reason ?? this.reason,
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
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (externalId.present) {
      map['external_id'] = Variable<String>(externalId.value);
    }
    if (relationType.present) {
      map['relation_type'] = Variable<String>(relationType.value);
    }
    if (primaryEntityType.present) {
      map['primary_entity_type'] = Variable<String>(primaryEntityType.value);
    }
    if (primaryEntityId.present) {
      map['primary_entity_id'] = Variable<String>(primaryEntityId.value);
    }
    if (relatedEntityType.present) {
      map['related_entity_type'] = Variable<String>(relatedEntityType.value);
    }
    if (relatedEntityId.present) {
      map['related_entity_id'] = Variable<String>(relatedEntityId.value);
    }
    if (leftKind.present) {
      map['left_kind'] = Variable<String>(leftKind.value);
    }
    if (leftId.present) {
      map['left_id'] = Variable<String>(leftId.value);
    }
    if (rightKind.present) {
      map['right_kind'] = Variable<String>(rightKind.value);
    }
    if (rightId.present) {
      map['right_id'] = Variable<String>(rightId.value);
    }
    if (leftEventId.present) {
      map['left_event_id'] = Variable<String>(leftEventId.value);
    }
    if (leftPlanBlockId.present) {
      map['left_plan_block_id'] = Variable<String>(leftPlanBlockId.value);
    }
    if (rightEventId.present) {
      map['right_event_id'] = Variable<String>(rightEventId.value);
    }
    if (rightPlanBlockId.present) {
      map['right_plan_block_id'] = Variable<String>(rightPlanBlockId.value);
    }
    if (conflictState.present) {
      map['conflict_state'] = Variable<String>(conflictState.value);
    }
    if (reason.present) {
      map['reason'] = Variable<String>(reason.value);
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
    return (StringBuffer('ScheduleRelationsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('source: $source, ')
          ..write('externalId: $externalId, ')
          ..write('relationType: $relationType, ')
          ..write('primaryEntityType: $primaryEntityType, ')
          ..write('primaryEntityId: $primaryEntityId, ')
          ..write('relatedEntityType: $relatedEntityType, ')
          ..write('relatedEntityId: $relatedEntityId, ')
          ..write('leftKind: $leftKind, ')
          ..write('leftId: $leftId, ')
          ..write('rightKind: $rightKind, ')
          ..write('rightId: $rightId, ')
          ..write('leftEventId: $leftEventId, ')
          ..write('leftPlanBlockId: $leftPlanBlockId, ')
          ..write('rightEventId: $rightEventId, ')
          ..write('rightPlanBlockId: $rightPlanBlockId, ')
          ..write('conflictState: $conflictState, ')
          ..write('reason: $reason, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScheduleRelationRulesTable extends ScheduleRelationRules
    with TableInfo<$ScheduleRelationRulesTable, ScheduleRelationRule> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScheduleRelationRulesTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _leftSeriesTypeMeta = const VerificationMeta(
    'leftSeriesType',
  );
  @override
  late final GeneratedColumn<String> leftSeriesType = GeneratedColumn<String>(
    'left_series_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _leftSeriesIdMeta = const VerificationMeta(
    'leftSeriesId',
  );
  @override
  late final GeneratedColumn<String> leftSeriesId = GeneratedColumn<String>(
    'left_series_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rightSeriesTypeMeta = const VerificationMeta(
    'rightSeriesType',
  );
  @override
  late final GeneratedColumn<String> rightSeriesType = GeneratedColumn<String>(
    'right_series_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rightSeriesIdMeta = const VerificationMeta(
    'rightSeriesId',
  );
  @override
  late final GeneratedColumn<String> rightSeriesId = GeneratedColumn<String>(
    'right_series_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conflictStateMeta = const VerificationMeta(
    'conflictState',
  );
  @override
  late final GeneratedColumn<String> conflictState = GeneratedColumn<String>(
    'conflict_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reasonMeta = const VerificationMeta('reason');
  @override
  late final GeneratedColumn<String> reason = GeneratedColumn<String>(
    'reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _effectiveFromMeta = const VerificationMeta(
    'effectiveFrom',
  );
  @override
  late final GeneratedColumn<String> effectiveFrom = GeneratedColumn<String>(
    'effective_from',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _effectiveThroughMeta = const VerificationMeta(
    'effectiveThrough',
  );
  @override
  late final GeneratedColumn<String> effectiveThrough = GeneratedColumn<String>(
    'effective_through',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
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
    accountId,
    leftSeriesType,
    leftSeriesId,
    rightSeriesType,
    rightSeriesId,
    conflictState,
    reason,
    effectiveFrom,
    effectiveThrough,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'schedule_relation_rules';
  @override
  VerificationContext validateIntegrity(
    Insertable<ScheduleRelationRule> instance, {
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
    if (data.containsKey('left_series_type')) {
      context.handle(
        _leftSeriesTypeMeta,
        leftSeriesType.isAcceptableOrUnknown(
          data['left_series_type']!,
          _leftSeriesTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_leftSeriesTypeMeta);
    }
    if (data.containsKey('left_series_id')) {
      context.handle(
        _leftSeriesIdMeta,
        leftSeriesId.isAcceptableOrUnknown(
          data['left_series_id']!,
          _leftSeriesIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_leftSeriesIdMeta);
    }
    if (data.containsKey('right_series_type')) {
      context.handle(
        _rightSeriesTypeMeta,
        rightSeriesType.isAcceptableOrUnknown(
          data['right_series_type']!,
          _rightSeriesTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_rightSeriesTypeMeta);
    }
    if (data.containsKey('right_series_id')) {
      context.handle(
        _rightSeriesIdMeta,
        rightSeriesId.isAcceptableOrUnknown(
          data['right_series_id']!,
          _rightSeriesIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_rightSeriesIdMeta);
    }
    if (data.containsKey('conflict_state')) {
      context.handle(
        _conflictStateMeta,
        conflictState.isAcceptableOrUnknown(
          data['conflict_state']!,
          _conflictStateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conflictStateMeta);
    }
    if (data.containsKey('reason')) {
      context.handle(
        _reasonMeta,
        reason.isAcceptableOrUnknown(data['reason']!, _reasonMeta),
      );
    }
    if (data.containsKey('effective_from')) {
      context.handle(
        _effectiveFromMeta,
        effectiveFrom.isAcceptableOrUnknown(
          data['effective_from']!,
          _effectiveFromMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_effectiveFromMeta);
    }
    if (data.containsKey('effective_through')) {
      context.handle(
        _effectiveThroughMeta,
        effectiveThrough.isAcceptableOrUnknown(
          data['effective_through']!,
          _effectiveThroughMeta,
        ),
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
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {
      accountId,
      leftSeriesType,
      leftSeriesId,
      rightSeriesType,
      rightSeriesId,
      effectiveFrom,
    },
  ];
  @override
  ScheduleRelationRule map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ScheduleRelationRule(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      leftSeriesType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}left_series_type'],
      )!,
      leftSeriesId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}left_series_id'],
      )!,
      rightSeriesType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}right_series_type'],
      )!,
      rightSeriesId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}right_series_id'],
      )!,
      conflictState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conflict_state'],
      )!,
      reason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reason'],
      ),
      effectiveFrom: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}effective_from'],
      )!,
      effectiveThrough: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}effective_through'],
      ),
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
  $ScheduleRelationRulesTable createAlias(String alias) {
    return $ScheduleRelationRulesTable(attachedDatabase, alias);
  }
}

class ScheduleRelationRule extends DataClass
    implements Insertable<ScheduleRelationRule> {
  final String id;
  final String accountId;
  final String leftSeriesType;
  final String leftSeriesId;
  final String rightSeriesType;
  final String rightSeriesId;
  final String conflictState;
  final String? reason;
  final String effectiveFrom;
  final String? effectiveThrough;
  final int createdAt;
  final int updatedAt;
  const ScheduleRelationRule({
    required this.id,
    required this.accountId,
    required this.leftSeriesType,
    required this.leftSeriesId,
    required this.rightSeriesType,
    required this.rightSeriesId,
    required this.conflictState,
    this.reason,
    required this.effectiveFrom,
    this.effectiveThrough,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['left_series_type'] = Variable<String>(leftSeriesType);
    map['left_series_id'] = Variable<String>(leftSeriesId);
    map['right_series_type'] = Variable<String>(rightSeriesType);
    map['right_series_id'] = Variable<String>(rightSeriesId);
    map['conflict_state'] = Variable<String>(conflictState);
    if (!nullToAbsent || reason != null) {
      map['reason'] = Variable<String>(reason);
    }
    map['effective_from'] = Variable<String>(effectiveFrom);
    if (!nullToAbsent || effectiveThrough != null) {
      map['effective_through'] = Variable<String>(effectiveThrough);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  ScheduleRelationRulesCompanion toCompanion(bool nullToAbsent) {
    return ScheduleRelationRulesCompanion(
      id: Value(id),
      accountId: Value(accountId),
      leftSeriesType: Value(leftSeriesType),
      leftSeriesId: Value(leftSeriesId),
      rightSeriesType: Value(rightSeriesType),
      rightSeriesId: Value(rightSeriesId),
      conflictState: Value(conflictState),
      reason: reason == null && nullToAbsent
          ? const Value.absent()
          : Value(reason),
      effectiveFrom: Value(effectiveFrom),
      effectiveThrough: effectiveThrough == null && nullToAbsent
          ? const Value.absent()
          : Value(effectiveThrough),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ScheduleRelationRule.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ScheduleRelationRule(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      leftSeriesType: serializer.fromJson<String>(json['leftSeriesType']),
      leftSeriesId: serializer.fromJson<String>(json['leftSeriesId']),
      rightSeriesType: serializer.fromJson<String>(json['rightSeriesType']),
      rightSeriesId: serializer.fromJson<String>(json['rightSeriesId']),
      conflictState: serializer.fromJson<String>(json['conflictState']),
      reason: serializer.fromJson<String?>(json['reason']),
      effectiveFrom: serializer.fromJson<String>(json['effectiveFrom']),
      effectiveThrough: serializer.fromJson<String?>(json['effectiveThrough']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'leftSeriesType': serializer.toJson<String>(leftSeriesType),
      'leftSeriesId': serializer.toJson<String>(leftSeriesId),
      'rightSeriesType': serializer.toJson<String>(rightSeriesType),
      'rightSeriesId': serializer.toJson<String>(rightSeriesId),
      'conflictState': serializer.toJson<String>(conflictState),
      'reason': serializer.toJson<String?>(reason),
      'effectiveFrom': serializer.toJson<String>(effectiveFrom),
      'effectiveThrough': serializer.toJson<String?>(effectiveThrough),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  ScheduleRelationRule copyWith({
    String? id,
    String? accountId,
    String? leftSeriesType,
    String? leftSeriesId,
    String? rightSeriesType,
    String? rightSeriesId,
    String? conflictState,
    Value<String?> reason = const Value.absent(),
    String? effectiveFrom,
    Value<String?> effectiveThrough = const Value.absent(),
    int? createdAt,
    int? updatedAt,
  }) => ScheduleRelationRule(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    leftSeriesType: leftSeriesType ?? this.leftSeriesType,
    leftSeriesId: leftSeriesId ?? this.leftSeriesId,
    rightSeriesType: rightSeriesType ?? this.rightSeriesType,
    rightSeriesId: rightSeriesId ?? this.rightSeriesId,
    conflictState: conflictState ?? this.conflictState,
    reason: reason.present ? reason.value : this.reason,
    effectiveFrom: effectiveFrom ?? this.effectiveFrom,
    effectiveThrough: effectiveThrough.present
        ? effectiveThrough.value
        : this.effectiveThrough,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ScheduleRelationRule copyWithCompanion(ScheduleRelationRulesCompanion data) {
    return ScheduleRelationRule(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      leftSeriesType: data.leftSeriesType.present
          ? data.leftSeriesType.value
          : this.leftSeriesType,
      leftSeriesId: data.leftSeriesId.present
          ? data.leftSeriesId.value
          : this.leftSeriesId,
      rightSeriesType: data.rightSeriesType.present
          ? data.rightSeriesType.value
          : this.rightSeriesType,
      rightSeriesId: data.rightSeriesId.present
          ? data.rightSeriesId.value
          : this.rightSeriesId,
      conflictState: data.conflictState.present
          ? data.conflictState.value
          : this.conflictState,
      reason: data.reason.present ? data.reason.value : this.reason,
      effectiveFrom: data.effectiveFrom.present
          ? data.effectiveFrom.value
          : this.effectiveFrom,
      effectiveThrough: data.effectiveThrough.present
          ? data.effectiveThrough.value
          : this.effectiveThrough,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ScheduleRelationRule(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('leftSeriesType: $leftSeriesType, ')
          ..write('leftSeriesId: $leftSeriesId, ')
          ..write('rightSeriesType: $rightSeriesType, ')
          ..write('rightSeriesId: $rightSeriesId, ')
          ..write('conflictState: $conflictState, ')
          ..write('reason: $reason, ')
          ..write('effectiveFrom: $effectiveFrom, ')
          ..write('effectiveThrough: $effectiveThrough, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    leftSeriesType,
    leftSeriesId,
    rightSeriesType,
    rightSeriesId,
    conflictState,
    reason,
    effectiveFrom,
    effectiveThrough,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScheduleRelationRule &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.leftSeriesType == this.leftSeriesType &&
          other.leftSeriesId == this.leftSeriesId &&
          other.rightSeriesType == this.rightSeriesType &&
          other.rightSeriesId == this.rightSeriesId &&
          other.conflictState == this.conflictState &&
          other.reason == this.reason &&
          other.effectiveFrom == this.effectiveFrom &&
          other.effectiveThrough == this.effectiveThrough &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ScheduleRelationRulesCompanion
    extends UpdateCompanion<ScheduleRelationRule> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> leftSeriesType;
  final Value<String> leftSeriesId;
  final Value<String> rightSeriesType;
  final Value<String> rightSeriesId;
  final Value<String> conflictState;
  final Value<String?> reason;
  final Value<String> effectiveFrom;
  final Value<String?> effectiveThrough;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const ScheduleRelationRulesCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.leftSeriesType = const Value.absent(),
    this.leftSeriesId = const Value.absent(),
    this.rightSeriesType = const Value.absent(),
    this.rightSeriesId = const Value.absent(),
    this.conflictState = const Value.absent(),
    this.reason = const Value.absent(),
    this.effectiveFrom = const Value.absent(),
    this.effectiveThrough = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ScheduleRelationRulesCompanion.insert({
    required String id,
    required String accountId,
    required String leftSeriesType,
    required String leftSeriesId,
    required String rightSeriesType,
    required String rightSeriesId,
    required String conflictState,
    this.reason = const Value.absent(),
    required String effectiveFrom,
    this.effectiveThrough = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       leftSeriesType = Value(leftSeriesType),
       leftSeriesId = Value(leftSeriesId),
       rightSeriesType = Value(rightSeriesType),
       rightSeriesId = Value(rightSeriesId),
       conflictState = Value(conflictState),
       effectiveFrom = Value(effectiveFrom),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<ScheduleRelationRule> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? leftSeriesType,
    Expression<String>? leftSeriesId,
    Expression<String>? rightSeriesType,
    Expression<String>? rightSeriesId,
    Expression<String>? conflictState,
    Expression<String>? reason,
    Expression<String>? effectiveFrom,
    Expression<String>? effectiveThrough,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (leftSeriesType != null) 'left_series_type': leftSeriesType,
      if (leftSeriesId != null) 'left_series_id': leftSeriesId,
      if (rightSeriesType != null) 'right_series_type': rightSeriesType,
      if (rightSeriesId != null) 'right_series_id': rightSeriesId,
      if (conflictState != null) 'conflict_state': conflictState,
      if (reason != null) 'reason': reason,
      if (effectiveFrom != null) 'effective_from': effectiveFrom,
      if (effectiveThrough != null) 'effective_through': effectiveThrough,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ScheduleRelationRulesCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? leftSeriesType,
    Value<String>? leftSeriesId,
    Value<String>? rightSeriesType,
    Value<String>? rightSeriesId,
    Value<String>? conflictState,
    Value<String?>? reason,
    Value<String>? effectiveFrom,
    Value<String?>? effectiveThrough,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return ScheduleRelationRulesCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      leftSeriesType: leftSeriesType ?? this.leftSeriesType,
      leftSeriesId: leftSeriesId ?? this.leftSeriesId,
      rightSeriesType: rightSeriesType ?? this.rightSeriesType,
      rightSeriesId: rightSeriesId ?? this.rightSeriesId,
      conflictState: conflictState ?? this.conflictState,
      reason: reason ?? this.reason,
      effectiveFrom: effectiveFrom ?? this.effectiveFrom,
      effectiveThrough: effectiveThrough ?? this.effectiveThrough,
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
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (leftSeriesType.present) {
      map['left_series_type'] = Variable<String>(leftSeriesType.value);
    }
    if (leftSeriesId.present) {
      map['left_series_id'] = Variable<String>(leftSeriesId.value);
    }
    if (rightSeriesType.present) {
      map['right_series_type'] = Variable<String>(rightSeriesType.value);
    }
    if (rightSeriesId.present) {
      map['right_series_id'] = Variable<String>(rightSeriesId.value);
    }
    if (conflictState.present) {
      map['conflict_state'] = Variable<String>(conflictState.value);
    }
    if (reason.present) {
      map['reason'] = Variable<String>(reason.value);
    }
    if (effectiveFrom.present) {
      map['effective_from'] = Variable<String>(effectiveFrom.value);
    }
    if (effectiveThrough.present) {
      map['effective_through'] = Variable<String>(effectiveThrough.value);
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
    return (StringBuffer('ScheduleRelationRulesCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('leftSeriesType: $leftSeriesType, ')
          ..write('leftSeriesId: $leftSeriesId, ')
          ..write('rightSeriesType: $rightSeriesType, ')
          ..write('rightSeriesId: $rightSeriesId, ')
          ..write('conflictState: $conflictState, ')
          ..write('reason: $reason, ')
          ..write('effectiveFrom: $effectiveFrom, ')
          ..write('effectiveThrough: $effectiveThrough, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RemindersTable extends Reminders
    with TableInfo<$RemindersTable, Reminder> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RemindersTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _targetTypeMeta = const VerificationMeta(
    'targetType',
  );
  @override
  late final GeneratedColumn<String> targetType = GeneratedColumn<String>(
    'target_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _targetIdMeta = const VerificationMeta(
    'targetId',
  );
  @override
  late final GeneratedColumn<String> targetId = GeneratedColumn<String>(
    'target_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _eventIdMeta = const VerificationMeta(
    'eventId',
  );
  @override
  late final GeneratedColumn<String> eventId = GeneratedColumn<String>(
    'event_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES calendar_events (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  @override
  late final GeneratedColumn<String> taskId = GeneratedColumn<String>(
    'task_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES tasks (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _planBlockIdMeta = const VerificationMeta(
    'planBlockId',
  );
  @override
  late final GeneratedColumn<String> planBlockId = GeneratedColumn<String>(
    'plan_block_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES plan_blocks (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _offsetMinutesMeta = const VerificationMeta(
    'offsetMinutes',
  );
  @override
  late final GeneratedColumn<int> offsetMinutes = GeneratedColumn<int>(
    'offset_minutes',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _triggerAtMeta = const VerificationMeta(
    'triggerAt',
  );
  @override
  late final GeneratedColumn<int> triggerAt = GeneratedColumn<int>(
    'trigger_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
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
  static const VerificationMeta _failureCodeMeta = const VerificationMeta(
    'failureCode',
  );
  @override
  late final GeneratedColumn<String> failureCode = GeneratedColumn<String>(
    'failure_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deliveredAtMeta = const VerificationMeta(
    'deliveredAt',
  );
  @override
  late final GeneratedColumn<int> deliveredAt = GeneratedColumn<int>(
    'delivered_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
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
    accountId,
    targetType,
    targetId,
    eventId,
    taskId,
    planBlockId,
    offsetMinutes,
    triggerAt,
    state,
    failureCode,
    deliveredAt,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reminders';
  @override
  VerificationContext validateIntegrity(
    Insertable<Reminder> instance, {
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
    if (data.containsKey('target_type')) {
      context.handle(
        _targetTypeMeta,
        targetType.isAcceptableOrUnknown(data['target_type']!, _targetTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_targetTypeMeta);
    }
    if (data.containsKey('target_id')) {
      context.handle(
        _targetIdMeta,
        targetId.isAcceptableOrUnknown(data['target_id']!, _targetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_targetIdMeta);
    }
    if (data.containsKey('event_id')) {
      context.handle(
        _eventIdMeta,
        eventId.isAcceptableOrUnknown(data['event_id']!, _eventIdMeta),
      );
    }
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    }
    if (data.containsKey('plan_block_id')) {
      context.handle(
        _planBlockIdMeta,
        planBlockId.isAcceptableOrUnknown(
          data['plan_block_id']!,
          _planBlockIdMeta,
        ),
      );
    }
    if (data.containsKey('offset_minutes')) {
      context.handle(
        _offsetMinutesMeta,
        offsetMinutes.isAcceptableOrUnknown(
          data['offset_minutes']!,
          _offsetMinutesMeta,
        ),
      );
    }
    if (data.containsKey('trigger_at')) {
      context.handle(
        _triggerAtMeta,
        triggerAt.isAcceptableOrUnknown(data['trigger_at']!, _triggerAtMeta),
      );
    } else if (isInserting) {
      context.missing(_triggerAtMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('failure_code')) {
      context.handle(
        _failureCodeMeta,
        failureCode.isAcceptableOrUnknown(
          data['failure_code']!,
          _failureCodeMeta,
        ),
      );
    }
    if (data.containsKey('delivered_at')) {
      context.handle(
        _deliveredAtMeta,
        deliveredAt.isAcceptableOrUnknown(
          data['delivered_at']!,
          _deliveredAtMeta,
        ),
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
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, targetType, targetId, triggerAt},
  ];
  @override
  Reminder map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Reminder(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      targetType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_type'],
      )!,
      targetId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_id'],
      )!,
      eventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_id'],
      ),
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_id'],
      ),
      planBlockId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}plan_block_id'],
      ),
      offsetMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}offset_minutes'],
      ),
      triggerAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}trigger_at'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      failureCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}failure_code'],
      ),
      deliveredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delivered_at'],
      ),
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
  $RemindersTable createAlias(String alias) {
    return $RemindersTable(attachedDatabase, alias);
  }
}

class Reminder extends DataClass implements Insertable<Reminder> {
  final String id;
  final String accountId;
  final String targetType;
  final String targetId;
  final String? eventId;
  final String? taskId;
  final String? planBlockId;
  final int? offsetMinutes;
  final int triggerAt;
  final String state;
  final String? failureCode;
  final int? deliveredAt;
  final int createdAt;
  final int updatedAt;
  const Reminder({
    required this.id,
    required this.accountId,
    required this.targetType,
    required this.targetId,
    this.eventId,
    this.taskId,
    this.planBlockId,
    this.offsetMinutes,
    required this.triggerAt,
    required this.state,
    this.failureCode,
    this.deliveredAt,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['account_id'] = Variable<String>(accountId);
    map['target_type'] = Variable<String>(targetType);
    map['target_id'] = Variable<String>(targetId);
    if (!nullToAbsent || eventId != null) {
      map['event_id'] = Variable<String>(eventId);
    }
    if (!nullToAbsent || taskId != null) {
      map['task_id'] = Variable<String>(taskId);
    }
    if (!nullToAbsent || planBlockId != null) {
      map['plan_block_id'] = Variable<String>(planBlockId);
    }
    if (!nullToAbsent || offsetMinutes != null) {
      map['offset_minutes'] = Variable<int>(offsetMinutes);
    }
    map['trigger_at'] = Variable<int>(triggerAt);
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || failureCode != null) {
      map['failure_code'] = Variable<String>(failureCode);
    }
    if (!nullToAbsent || deliveredAt != null) {
      map['delivered_at'] = Variable<int>(deliveredAt);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  RemindersCompanion toCompanion(bool nullToAbsent) {
    return RemindersCompanion(
      id: Value(id),
      accountId: Value(accountId),
      targetType: Value(targetType),
      targetId: Value(targetId),
      eventId: eventId == null && nullToAbsent
          ? const Value.absent()
          : Value(eventId),
      taskId: taskId == null && nullToAbsent
          ? const Value.absent()
          : Value(taskId),
      planBlockId: planBlockId == null && nullToAbsent
          ? const Value.absent()
          : Value(planBlockId),
      offsetMinutes: offsetMinutes == null && nullToAbsent
          ? const Value.absent()
          : Value(offsetMinutes),
      triggerAt: Value(triggerAt),
      state: Value(state),
      failureCode: failureCode == null && nullToAbsent
          ? const Value.absent()
          : Value(failureCode),
      deliveredAt: deliveredAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deliveredAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Reminder.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Reminder(
      id: serializer.fromJson<String>(json['id']),
      accountId: serializer.fromJson<String>(json['accountId']),
      targetType: serializer.fromJson<String>(json['targetType']),
      targetId: serializer.fromJson<String>(json['targetId']),
      eventId: serializer.fromJson<String?>(json['eventId']),
      taskId: serializer.fromJson<String?>(json['taskId']),
      planBlockId: serializer.fromJson<String?>(json['planBlockId']),
      offsetMinutes: serializer.fromJson<int?>(json['offsetMinutes']),
      triggerAt: serializer.fromJson<int>(json['triggerAt']),
      state: serializer.fromJson<String>(json['state']),
      failureCode: serializer.fromJson<String?>(json['failureCode']),
      deliveredAt: serializer.fromJson<int?>(json['deliveredAt']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'accountId': serializer.toJson<String>(accountId),
      'targetType': serializer.toJson<String>(targetType),
      'targetId': serializer.toJson<String>(targetId),
      'eventId': serializer.toJson<String?>(eventId),
      'taskId': serializer.toJson<String?>(taskId),
      'planBlockId': serializer.toJson<String?>(planBlockId),
      'offsetMinutes': serializer.toJson<int?>(offsetMinutes),
      'triggerAt': serializer.toJson<int>(triggerAt),
      'state': serializer.toJson<String>(state),
      'failureCode': serializer.toJson<String?>(failureCode),
      'deliveredAt': serializer.toJson<int?>(deliveredAt),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  Reminder copyWith({
    String? id,
    String? accountId,
    String? targetType,
    String? targetId,
    Value<String?> eventId = const Value.absent(),
    Value<String?> taskId = const Value.absent(),
    Value<String?> planBlockId = const Value.absent(),
    Value<int?> offsetMinutes = const Value.absent(),
    int? triggerAt,
    String? state,
    Value<String?> failureCode = const Value.absent(),
    Value<int?> deliveredAt = const Value.absent(),
    int? createdAt,
    int? updatedAt,
  }) => Reminder(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    targetType: targetType ?? this.targetType,
    targetId: targetId ?? this.targetId,
    eventId: eventId.present ? eventId.value : this.eventId,
    taskId: taskId.present ? taskId.value : this.taskId,
    planBlockId: planBlockId.present ? planBlockId.value : this.planBlockId,
    offsetMinutes: offsetMinutes.present
        ? offsetMinutes.value
        : this.offsetMinutes,
    triggerAt: triggerAt ?? this.triggerAt,
    state: state ?? this.state,
    failureCode: failureCode.present ? failureCode.value : this.failureCode,
    deliveredAt: deliveredAt.present ? deliveredAt.value : this.deliveredAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  Reminder copyWithCompanion(RemindersCompanion data) {
    return Reminder(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      targetType: data.targetType.present
          ? data.targetType.value
          : this.targetType,
      targetId: data.targetId.present ? data.targetId.value : this.targetId,
      eventId: data.eventId.present ? data.eventId.value : this.eventId,
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      planBlockId: data.planBlockId.present
          ? data.planBlockId.value
          : this.planBlockId,
      offsetMinutes: data.offsetMinutes.present
          ? data.offsetMinutes.value
          : this.offsetMinutes,
      triggerAt: data.triggerAt.present ? data.triggerAt.value : this.triggerAt,
      state: data.state.present ? data.state.value : this.state,
      failureCode: data.failureCode.present
          ? data.failureCode.value
          : this.failureCode,
      deliveredAt: data.deliveredAt.present
          ? data.deliveredAt.value
          : this.deliveredAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Reminder(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('targetType: $targetType, ')
          ..write('targetId: $targetId, ')
          ..write('eventId: $eventId, ')
          ..write('taskId: $taskId, ')
          ..write('planBlockId: $planBlockId, ')
          ..write('offsetMinutes: $offsetMinutes, ')
          ..write('triggerAt: $triggerAt, ')
          ..write('state: $state, ')
          ..write('failureCode: $failureCode, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    targetType,
    targetId,
    eventId,
    taskId,
    planBlockId,
    offsetMinutes,
    triggerAt,
    state,
    failureCode,
    deliveredAt,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Reminder &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.targetType == this.targetType &&
          other.targetId == this.targetId &&
          other.eventId == this.eventId &&
          other.taskId == this.taskId &&
          other.planBlockId == this.planBlockId &&
          other.offsetMinutes == this.offsetMinutes &&
          other.triggerAt == this.triggerAt &&
          other.state == this.state &&
          other.failureCode == this.failureCode &&
          other.deliveredAt == this.deliveredAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class RemindersCompanion extends UpdateCompanion<Reminder> {
  final Value<String> id;
  final Value<String> accountId;
  final Value<String> targetType;
  final Value<String> targetId;
  final Value<String?> eventId;
  final Value<String?> taskId;
  final Value<String?> planBlockId;
  final Value<int?> offsetMinutes;
  final Value<int> triggerAt;
  final Value<String> state;
  final Value<String?> failureCode;
  final Value<int?> deliveredAt;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const RemindersCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.targetType = const Value.absent(),
    this.targetId = const Value.absent(),
    this.eventId = const Value.absent(),
    this.taskId = const Value.absent(),
    this.planBlockId = const Value.absent(),
    this.offsetMinutes = const Value.absent(),
    this.triggerAt = const Value.absent(),
    this.state = const Value.absent(),
    this.failureCode = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RemindersCompanion.insert({
    required String id,
    required String accountId,
    required String targetType,
    required String targetId,
    this.eventId = const Value.absent(),
    this.taskId = const Value.absent(),
    this.planBlockId = const Value.absent(),
    this.offsetMinutes = const Value.absent(),
    required int triggerAt,
    required String state,
    this.failureCode = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       accountId = Value(accountId),
       targetType = Value(targetType),
       targetId = Value(targetId),
       triggerAt = Value(triggerAt),
       state = Value(state),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Reminder> custom({
    Expression<String>? id,
    Expression<String>? accountId,
    Expression<String>? targetType,
    Expression<String>? targetId,
    Expression<String>? eventId,
    Expression<String>? taskId,
    Expression<String>? planBlockId,
    Expression<int>? offsetMinutes,
    Expression<int>? triggerAt,
    Expression<String>? state,
    Expression<String>? failureCode,
    Expression<int>? deliveredAt,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (targetType != null) 'target_type': targetType,
      if (targetId != null) 'target_id': targetId,
      if (eventId != null) 'event_id': eventId,
      if (taskId != null) 'task_id': taskId,
      if (planBlockId != null) 'plan_block_id': planBlockId,
      if (offsetMinutes != null) 'offset_minutes': offsetMinutes,
      if (triggerAt != null) 'trigger_at': triggerAt,
      if (state != null) 'state': state,
      if (failureCode != null) 'failure_code': failureCode,
      if (deliveredAt != null) 'delivered_at': deliveredAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RemindersCompanion copyWith({
    Value<String>? id,
    Value<String>? accountId,
    Value<String>? targetType,
    Value<String>? targetId,
    Value<String?>? eventId,
    Value<String?>? taskId,
    Value<String?>? planBlockId,
    Value<int?>? offsetMinutes,
    Value<int>? triggerAt,
    Value<String>? state,
    Value<String?>? failureCode,
    Value<int?>? deliveredAt,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return RemindersCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      targetType: targetType ?? this.targetType,
      targetId: targetId ?? this.targetId,
      eventId: eventId ?? this.eventId,
      taskId: taskId ?? this.taskId,
      planBlockId: planBlockId ?? this.planBlockId,
      offsetMinutes: offsetMinutes ?? this.offsetMinutes,
      triggerAt: triggerAt ?? this.triggerAt,
      state: state ?? this.state,
      failureCode: failureCode ?? this.failureCode,
      deliveredAt: deliveredAt ?? this.deliveredAt,
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
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (targetType.present) {
      map['target_type'] = Variable<String>(targetType.value);
    }
    if (targetId.present) {
      map['target_id'] = Variable<String>(targetId.value);
    }
    if (eventId.present) {
      map['event_id'] = Variable<String>(eventId.value);
    }
    if (taskId.present) {
      map['task_id'] = Variable<String>(taskId.value);
    }
    if (planBlockId.present) {
      map['plan_block_id'] = Variable<String>(planBlockId.value);
    }
    if (offsetMinutes.present) {
      map['offset_minutes'] = Variable<int>(offsetMinutes.value);
    }
    if (triggerAt.present) {
      map['trigger_at'] = Variable<int>(triggerAt.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (failureCode.present) {
      map['failure_code'] = Variable<String>(failureCode.value);
    }
    if (deliveredAt.present) {
      map['delivered_at'] = Variable<int>(deliveredAt.value);
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
    return (StringBuffer('RemindersCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('targetType: $targetType, ')
          ..write('targetId: $targetId, ')
          ..write('eventId: $eventId, ')
          ..write('taskId: $taskId, ')
          ..write('planBlockId: $planBlockId, ')
          ..write('offsetMinutes: $offsetMinutes, ')
          ..write('triggerAt: $triggerAt, ')
          ..write('state: $state, ')
          ..write('failureCode: $failureCode, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $UndoSlotTable extends UndoSlot
    with TableInfo<$UndoSlotTable, UndoSlotData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UndoSlotTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _slotMeta = const VerificationMeta('slot');
  @override
  late final GeneratedColumn<int> slot = GeneratedColumn<int>(
    'slot',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _commandIdMeta = const VerificationMeta(
    'commandId',
  );
  @override
  late final GeneratedColumn<String> commandId = GeneratedColumn<String>(
    'command_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<int> expiresAt = GeneratedColumn<int>(
    'expires_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
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
  @override
  List<GeneratedColumn> get $columns => [
    slot,
    commandId,
    payload,
    expiresAt,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'undo_slot';
  @override
  VerificationContext validateIntegrity(
    Insertable<UndoSlotData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('slot')) {
      context.handle(
        _slotMeta,
        slot.isAcceptableOrUnknown(data['slot']!, _slotMeta),
      );
    }
    if (data.containsKey('command_id')) {
      context.handle(
        _commandIdMeta,
        commandId.isAcceptableOrUnknown(data['command_id']!, _commandIdMeta),
      );
    } else if (isInserting) {
      context.missing(_commandIdMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
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
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {slot};
  @override
  UndoSlotData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UndoSlotData(
      slot: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}slot'],
      )!,
      commandId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}command_id'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}expires_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $UndoSlotTable createAlias(String alias) {
    return $UndoSlotTable(attachedDatabase, alias);
  }
}

class UndoSlotData extends DataClass implements Insertable<UndoSlotData> {
  final int slot;
  final String commandId;
  final String payload;
  final int? expiresAt;
  final int createdAt;
  const UndoSlotData({
    required this.slot,
    required this.commandId,
    required this.payload,
    this.expiresAt,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['slot'] = Variable<int>(slot);
    map['command_id'] = Variable<String>(commandId);
    map['payload'] = Variable<String>(payload);
    if (!nullToAbsent || expiresAt != null) {
      map['expires_at'] = Variable<int>(expiresAt);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  UndoSlotCompanion toCompanion(bool nullToAbsent) {
    return UndoSlotCompanion(
      slot: Value(slot),
      commandId: Value(commandId),
      payload: Value(payload),
      expiresAt: expiresAt == null && nullToAbsent
          ? const Value.absent()
          : Value(expiresAt),
      createdAt: Value(createdAt),
    );
  }

  factory UndoSlotData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UndoSlotData(
      slot: serializer.fromJson<int>(json['slot']),
      commandId: serializer.fromJson<String>(json['commandId']),
      payload: serializer.fromJson<String>(json['payload']),
      expiresAt: serializer.fromJson<int?>(json['expiresAt']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'slot': serializer.toJson<int>(slot),
      'commandId': serializer.toJson<String>(commandId),
      'payload': serializer.toJson<String>(payload),
      'expiresAt': serializer.toJson<int?>(expiresAt),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  UndoSlotData copyWith({
    int? slot,
    String? commandId,
    String? payload,
    Value<int?> expiresAt = const Value.absent(),
    int? createdAt,
  }) => UndoSlotData(
    slot: slot ?? this.slot,
    commandId: commandId ?? this.commandId,
    payload: payload ?? this.payload,
    expiresAt: expiresAt.present ? expiresAt.value : this.expiresAt,
    createdAt: createdAt ?? this.createdAt,
  );
  UndoSlotData copyWithCompanion(UndoSlotCompanion data) {
    return UndoSlotData(
      slot: data.slot.present ? data.slot.value : this.slot,
      commandId: data.commandId.present ? data.commandId.value : this.commandId,
      payload: data.payload.present ? data.payload.value : this.payload,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UndoSlotData(')
          ..write('slot: $slot, ')
          ..write('commandId: $commandId, ')
          ..write('payload: $payload, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(slot, commandId, payload, expiresAt, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UndoSlotData &&
          other.slot == this.slot &&
          other.commandId == this.commandId &&
          other.payload == this.payload &&
          other.expiresAt == this.expiresAt &&
          other.createdAt == this.createdAt);
}

class UndoSlotCompanion extends UpdateCompanion<UndoSlotData> {
  final Value<int> slot;
  final Value<String> commandId;
  final Value<String> payload;
  final Value<int?> expiresAt;
  final Value<int> createdAt;
  const UndoSlotCompanion({
    this.slot = const Value.absent(),
    this.commandId = const Value.absent(),
    this.payload = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  UndoSlotCompanion.insert({
    this.slot = const Value.absent(),
    required String commandId,
    required String payload,
    this.expiresAt = const Value.absent(),
    required int createdAt,
  }) : commandId = Value(commandId),
       payload = Value(payload),
       createdAt = Value(createdAt);
  static Insertable<UndoSlotData> custom({
    Expression<int>? slot,
    Expression<String>? commandId,
    Expression<String>? payload,
    Expression<int>? expiresAt,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (slot != null) 'slot': slot,
      if (commandId != null) 'command_id': commandId,
      if (payload != null) 'payload': payload,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  UndoSlotCompanion copyWith({
    Value<int>? slot,
    Value<String>? commandId,
    Value<String>? payload,
    Value<int?>? expiresAt,
    Value<int>? createdAt,
  }) {
    return UndoSlotCompanion(
      slot: slot ?? this.slot,
      commandId: commandId ?? this.commandId,
      payload: payload ?? this.payload,
      expiresAt: expiresAt ?? this.expiresAt,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (slot.present) {
      map['slot'] = Variable<int>(slot.value);
    }
    if (commandId.present) {
      map['command_id'] = Variable<String>(commandId.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<int>(expiresAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UndoSlotCompanion(')
          ..write('slot: $slot, ')
          ..write('commandId: $commandId, ')
          ..write('payload: $payload, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('createdAt: $createdAt')
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
  late final $CourseSeriesTable courseSeries = $CourseSeriesTable(this);
  late final $CalendarEventSeriesTable calendarEventSeries =
      $CalendarEventSeriesTable(this);
  late final $CalendarEventsTable calendarEvents = $CalendarEventsTable(this);
  late final $CalendarEventOccurrenceExceptionsTable
  calendarEventOccurrenceExceptions = $CalendarEventOccurrenceExceptionsTable(
    this,
  );
  late final $UserOverlaysTable userOverlays = $UserOverlaysTable(this);
  late final $TasksTable tasks = $TasksTable(this);
  late final $PlanBlocksTable planBlocks = $PlanBlocksTable(this);
  late final $TaskEventLinksTable taskEventLinks = $TaskEventLinksTable(this);
  late final $ScheduleRelationsTable scheduleRelations =
      $ScheduleRelationsTable(this);
  late final $ScheduleRelationRulesTable scheduleRelationRules =
      $ScheduleRelationRulesTable(this);
  late final $RemindersTable reminders = $RemindersTable(this);
  late final $UndoSlotTable undoSlot = $UndoSlotTable(this);
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
    courseSeries,
    calendarEventSeries,
    calendarEvents,
    calendarEventOccurrenceExceptions,
    userOverlays,
    tasks,
    planBlocks,
    taskEventLinks,
    scheduleRelations,
    scheduleRelationRules,
    reminders,
    undoSlot,
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
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('course_series', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('calendar_event_series', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('calendar_events', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'calendar_event_series',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('calendar_events', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [
        TableUpdate(
          'calendar_event_occurrence_exceptions',
          kind: UpdateKind.delete,
        ),
      ],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'calendar_event_series',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [
        TableUpdate(
          'calendar_event_occurrence_exceptions',
          kind: UpdateKind.delete,
        ),
      ],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('user_overlays', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'calendar_events',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('user_overlays', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('tasks', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('plan_blocks', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'tasks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('plan_blocks', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('task_event_links', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'tasks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('task_event_links', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'calendar_events',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('task_event_links', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('schedule_relations', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'calendar_events',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('schedule_relations', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'plan_blocks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('schedule_relations', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'calendar_events',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('schedule_relations', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'plan_blocks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('schedule_relations', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('schedule_relation_rules', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('reminders', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'calendar_events',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('reminders', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'tasks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('reminders', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'plan_blocks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('reminders', kind: UpdateKind.delete)],
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

  static MultiTypedResultKey<$ImportBatchesTable, List<ImportBatch>>
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

  static MultiTypedResultKey<$CourseSeriesTable, List<CourseSery>>
  _courseSeriesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.courseSeries,
    aliasName: 'local_accounts__id__course_series__account_id',
  );

  $$CourseSeriesTableProcessedTableManager get courseSeriesRefs {
    final manager = $$CourseSeriesTableTableManager(
      $_db,
      $_db.courseSeries,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_courseSeriesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$CalendarEventSeriesTable, List<CalendarEventSery>>
  _calendarEventSeriesRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.calendarEventSeries,
        aliasName: 'local_accounts__id__calendar_event_series__account_id',
      );

  $$CalendarEventSeriesTableProcessedTableManager get calendarEventSeriesRefs {
    final manager = $$CalendarEventSeriesTableTableManager(
      $_db,
      $_db.calendarEventSeries,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _calendarEventSeriesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$CalendarEventsTable, List<CalendarEvent>>
  _calendarEventsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.calendarEvents,
    aliasName: 'local_accounts__id__calendar_events__account_id',
  );

  $$CalendarEventsTableProcessedTableManager get calendarEventsRefs {
    final manager = $$CalendarEventsTableTableManager(
      $_db,
      $_db.calendarEvents,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_calendarEventsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $CalendarEventOccurrenceExceptionsTable,
    List<CalendarEventOccurrenceException>
  >
  _calendarEventOccurrenceExceptionsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.calendarEventOccurrenceExceptions,
    aliasName:
        'local_accounts__id__calendar_event_occurrence_exceptions__account_id',
  );

  $$CalendarEventOccurrenceExceptionsTableProcessedTableManager
  get calendarEventOccurrenceExceptionsRefs {
    final manager = $$CalendarEventOccurrenceExceptionsTableTableManager(
      $_db,
      $_db.calendarEventOccurrenceExceptions,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _calendarEventOccurrenceExceptionsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$UserOverlaysTable, List<UserOverlay>>
  _userOverlaysRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.userOverlays,
    aliasName: 'local_accounts__id__user_overlays__account_id',
  );

  $$UserOverlaysTableProcessedTableManager get userOverlaysRefs {
    final manager = $$UserOverlaysTableTableManager(
      $_db,
      $_db.userOverlays,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_userOverlaysRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$TasksTable, List<Task>> _tasksRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.tasks,
    aliasName: 'local_accounts__id__tasks__account_id',
  );

  $$TasksTableProcessedTableManager get tasksRefs {
    final manager = $$TasksTableTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_tasksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$PlanBlocksTable, List<PlanBlock>>
  _planBlocksRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.planBlocks,
    aliasName: 'local_accounts__id__plan_blocks__account_id',
  );

  $$PlanBlocksTableProcessedTableManager get planBlocksRefs {
    final manager = $$PlanBlocksTableTableManager(
      $_db,
      $_db.planBlocks,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_planBlocksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$TaskEventLinksTable, List<TaskEventLink>>
  _taskEventLinksRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.taskEventLinks,
    aliasName: 'local_accounts__id__task_event_links__account_id',
  );

  $$TaskEventLinksTableProcessedTableManager get taskEventLinksRefs {
    final manager = $$TaskEventLinksTableTableManager(
      $_db,
      $_db.taskEventLinks,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_taskEventLinksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ScheduleRelationsTable, List<ScheduleRelation>>
  _scheduleRelationsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.scheduleRelations,
        aliasName: 'local_accounts__id__schedule_relations__account_id',
      );

  $$ScheduleRelationsTableProcessedTableManager get scheduleRelationsRefs {
    final manager = $$ScheduleRelationsTableTableManager(
      $_db,
      $_db.scheduleRelations,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _scheduleRelationsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $ScheduleRelationRulesTable,
    List<ScheduleRelationRule>
  >
  _scheduleRelationRulesRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.scheduleRelationRules,
        aliasName: 'local_accounts__id__schedule_relation_rules__account_id',
      );

  $$ScheduleRelationRulesTableProcessedTableManager
  get scheduleRelationRulesRefs {
    final manager = $$ScheduleRelationRulesTableTableManager(
      $_db,
      $_db.scheduleRelationRules,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _scheduleRelationRulesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$RemindersTable, List<Reminder>>
  _remindersRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.reminders,
    aliasName: 'local_accounts__id__reminders__account_id',
  );

  $$RemindersTableProcessedTableManager get remindersRefs {
    final manager = $$RemindersTableTableManager(
      $_db,
      $_db.reminders,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_remindersRefsTable($_db));
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

  Expression<bool> courseSeriesRefs(
    Expression<bool> Function($$CourseSeriesTableFilterComposer f) f,
  ) {
    final $$CourseSeriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.courseSeries,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CourseSeriesTableFilterComposer(
            $db: $db,
            $table: $db.courseSeries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> calendarEventSeriesRefs(
    Expression<bool> Function($$CalendarEventSeriesTableFilterComposer f) f,
  ) {
    final $$CalendarEventSeriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.calendarEventSeries,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventSeriesTableFilterComposer(
            $db: $db,
            $table: $db.calendarEventSeries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> calendarEventsRefs(
    Expression<bool> Function($$CalendarEventsTableFilterComposer f) f,
  ) {
    final $$CalendarEventsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableFilterComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> calendarEventOccurrenceExceptionsRefs(
    Expression<bool> Function(
      $$CalendarEventOccurrenceExceptionsTableFilterComposer f,
    )
    f,
  ) {
    final $$CalendarEventOccurrenceExceptionsTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.calendarEventOccurrenceExceptions,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CalendarEventOccurrenceExceptionsTableFilterComposer(
                $db: $db,
                $table: $db.calendarEventOccurrenceExceptions,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<bool> userOverlaysRefs(
    Expression<bool> Function($$UserOverlaysTableFilterComposer f) f,
  ) {
    final $$UserOverlaysTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.userOverlays,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$UserOverlaysTableFilterComposer(
            $db: $db,
            $table: $db.userOverlays,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> tasksRefs(
    Expression<bool> Function($$TasksTableFilterComposer f) f,
  ) {
    final $$TasksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> planBlocksRefs(
    Expression<bool> Function($$PlanBlocksTableFilterComposer f) f,
  ) {
    final $$PlanBlocksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableFilterComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> taskEventLinksRefs(
    Expression<bool> Function($$TaskEventLinksTableFilterComposer f) f,
  ) {
    final $$TaskEventLinksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskEventLinks,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskEventLinksTableFilterComposer(
            $db: $db,
            $table: $db.taskEventLinks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> scheduleRelationsRefs(
    Expression<bool> Function($$ScheduleRelationsTableFilterComposer f) f,
  ) {
    final $$ScheduleRelationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scheduleRelations,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScheduleRelationsTableFilterComposer(
            $db: $db,
            $table: $db.scheduleRelations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> scheduleRelationRulesRefs(
    Expression<bool> Function($$ScheduleRelationRulesTableFilterComposer f) f,
  ) {
    final $$ScheduleRelationRulesTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.scheduleRelationRules,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ScheduleRelationRulesTableFilterComposer(
                $db: $db,
                $table: $db.scheduleRelationRules,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<bool> remindersRefs(
    Expression<bool> Function($$RemindersTableFilterComposer f) f,
  ) {
    final $$RemindersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.reminders,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RemindersTableFilterComposer(
            $db: $db,
            $table: $db.reminders,
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

  Expression<T> courseSeriesRefs<T extends Object>(
    Expression<T> Function($$CourseSeriesTableAnnotationComposer a) f,
  ) {
    final $$CourseSeriesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.courseSeries,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CourseSeriesTableAnnotationComposer(
            $db: $db,
            $table: $db.courseSeries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> calendarEventSeriesRefs<T extends Object>(
    Expression<T> Function($$CalendarEventSeriesTableAnnotationComposer a) f,
  ) {
    final $$CalendarEventSeriesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.calendarEventSeries,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CalendarEventSeriesTableAnnotationComposer(
                $db: $db,
                $table: $db.calendarEventSeries,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> calendarEventsRefs<T extends Object>(
    Expression<T> Function($$CalendarEventsTableAnnotationComposer a) f,
  ) {
    final $$CalendarEventsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableAnnotationComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> calendarEventOccurrenceExceptionsRefs<T extends Object>(
    Expression<T> Function(
      $$CalendarEventOccurrenceExceptionsTableAnnotationComposer a,
    )
    f,
  ) {
    final $$CalendarEventOccurrenceExceptionsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.calendarEventOccurrenceExceptions,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CalendarEventOccurrenceExceptionsTableAnnotationComposer(
                $db: $db,
                $table: $db.calendarEventOccurrenceExceptions,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> userOverlaysRefs<T extends Object>(
    Expression<T> Function($$UserOverlaysTableAnnotationComposer a) f,
  ) {
    final $$UserOverlaysTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.userOverlays,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$UserOverlaysTableAnnotationComposer(
            $db: $db,
            $table: $db.userOverlays,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> tasksRefs<T extends Object>(
    Expression<T> Function($$TasksTableAnnotationComposer a) f,
  ) {
    final $$TasksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> planBlocksRefs<T extends Object>(
    Expression<T> Function($$PlanBlocksTableAnnotationComposer a) f,
  ) {
    final $$PlanBlocksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableAnnotationComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> taskEventLinksRefs<T extends Object>(
    Expression<T> Function($$TaskEventLinksTableAnnotationComposer a) f,
  ) {
    final $$TaskEventLinksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskEventLinks,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskEventLinksTableAnnotationComposer(
            $db: $db,
            $table: $db.taskEventLinks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> scheduleRelationsRefs<T extends Object>(
    Expression<T> Function($$ScheduleRelationsTableAnnotationComposer a) f,
  ) {
    final $$ScheduleRelationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.scheduleRelations,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ScheduleRelationsTableAnnotationComposer(
                $db: $db,
                $table: $db.scheduleRelations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> scheduleRelationRulesRefs<T extends Object>(
    Expression<T> Function($$ScheduleRelationRulesTableAnnotationComposer a) f,
  ) {
    final $$ScheduleRelationRulesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.scheduleRelationRules,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ScheduleRelationRulesTableAnnotationComposer(
                $db: $db,
                $table: $db.scheduleRelationRules,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> remindersRefs<T extends Object>(
    Expression<T> Function($$RemindersTableAnnotationComposer a) f,
  ) {
    final $$RemindersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.reminders,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RemindersTableAnnotationComposer(
            $db: $db,
            $table: $db.reminders,
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
            bool courseSeriesRefs,
            bool calendarEventSeriesRefs,
            bool calendarEventsRefs,
            bool calendarEventOccurrenceExceptionsRefs,
            bool userOverlaysRefs,
            bool tasksRefs,
            bool planBlocksRefs,
            bool taskEventLinksRefs,
            bool scheduleRelationsRefs,
            bool scheduleRelationRulesRefs,
            bool remindersRefs,
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
                courseSeriesRefs = false,
                calendarEventSeriesRefs = false,
                calendarEventsRefs = false,
                calendarEventOccurrenceExceptionsRefs = false,
                userOverlaysRefs = false,
                tasksRefs = false,
                planBlocksRefs = false,
                taskEventLinksRefs = false,
                scheduleRelationsRefs = false,
                scheduleRelationRulesRefs = false,
                remindersRefs = false,
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
                    if (courseSeriesRefs) db.courseSeries,
                    if (calendarEventSeriesRefs) db.calendarEventSeries,
                    if (calendarEventsRefs) db.calendarEvents,
                    if (calendarEventOccurrenceExceptionsRefs)
                      db.calendarEventOccurrenceExceptions,
                    if (userOverlaysRefs) db.userOverlays,
                    if (tasksRefs) db.tasks,
                    if (planBlocksRefs) db.planBlocks,
                    if (taskEventLinksRefs) db.taskEventLinks,
                    if (scheduleRelationsRefs) db.scheduleRelations,
                    if (scheduleRelationRulesRefs) db.scheduleRelationRules,
                    if (remindersRefs) db.reminders,
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
                          ImportBatch
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
                      if (courseSeriesRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          CourseSery
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._courseSeriesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).courseSeriesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (calendarEventSeriesRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          CalendarEventSery
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._calendarEventSeriesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).calendarEventSeriesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (calendarEventsRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          CalendarEvent
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._calendarEventsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).calendarEventsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (calendarEventOccurrenceExceptionsRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          CalendarEventOccurrenceException
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._calendarEventOccurrenceExceptionsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).calendarEventOccurrenceExceptionsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (userOverlaysRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          UserOverlay
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._userOverlaysRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).userOverlaysRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (tasksRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          Task
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._tasksRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).tasksRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (planBlocksRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          PlanBlock
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._planBlocksRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).planBlocksRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (taskEventLinksRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          TaskEventLink
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._taskEventLinksRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).taskEventLinksRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (scheduleRelationsRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          ScheduleRelation
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._scheduleRelationsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).scheduleRelationsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (scheduleRelationRulesRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          ScheduleRelationRule
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._scheduleRelationRulesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).scheduleRelationRulesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (remindersRefs)
                        await $_getPrefetchedData<
                          LocalAccount,
                          $LocalAccountsTable,
                          Reminder
                        >(
                          currentTable: table,
                          referencedTable: $$LocalAccountsTableReferences
                              ._remindersRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).remindersRefs,
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
        bool courseSeriesRefs,
        bool calendarEventSeriesRefs,
        bool calendarEventsRefs,
        bool calendarEventOccurrenceExceptionsRefs,
        bool userOverlaysRefs,
        bool tasksRefs,
        bool planBlocksRefs,
        bool taskEventLinksRefs,
        bool scheduleRelationsRefs,
        bool scheduleRelationRulesRefs,
        bool remindersRefs,
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
    extends BaseReferences<_$AppDatabase, $ImportBatchesTable, ImportBatch> {
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
          ImportBatch,
          $$ImportBatchesTableFilterComposer,
          $$ImportBatchesTableOrderingComposer,
          $$ImportBatchesTableAnnotationComposer,
          $$ImportBatchesTableCreateCompanionBuilder,
          $$ImportBatchesTableUpdateCompanionBuilder,
          (ImportBatch, $$ImportBatchesTableReferences),
          ImportBatch,
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
                          ImportBatch,
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
                          ImportBatch,
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
      ImportBatch,
      $$ImportBatchesTableFilterComposer,
      $$ImportBatchesTableOrderingComposer,
      $$ImportBatchesTableAnnotationComposer,
      $$ImportBatchesTableCreateCompanionBuilder,
      $$ImportBatchesTableUpdateCompanionBuilder,
      (ImportBatch, $$ImportBatchesTableReferences),
      ImportBatch,
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
typedef $$CourseSeriesTableCreateCompanionBuilder =
    CourseSeriesCompanion Function({
      required String id,
      required String accountId,
      required String source,
      required String externalId,
      required String title,
      Value<String?> courseCode,
      required String semesterKey,
      Value<String> participantsJson,
      required String sourceDetailsJson,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$CourseSeriesTableUpdateCompanionBuilder =
    CourseSeriesCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> source,
      Value<String> externalId,
      Value<String> title,
      Value<String?> courseCode,
      Value<String> semesterKey,
      Value<String> participantsJson,
      Value<String> sourceDetailsJson,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$CourseSeriesTableReferences
    extends BaseReferences<_$AppDatabase, $CourseSeriesTable, CourseSery> {
  $$CourseSeriesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('course_series__account_id__local_accounts__id');

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

class $$CourseSeriesTableFilterComposer
    extends Composer<_$AppDatabase, $CourseSeriesTable> {
  $$CourseSeriesTableFilterComposer({
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

  ColumnFilters<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get courseCode => $composableBuilder(
    column: $table.courseCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get semesterKey => $composableBuilder(
    column: $table.semesterKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get participantsJson => $composableBuilder(
    column: $table.participantsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceDetailsJson => $composableBuilder(
    column: $table.sourceDetailsJson,
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

class $$CourseSeriesTableOrderingComposer
    extends Composer<_$AppDatabase, $CourseSeriesTable> {
  $$CourseSeriesTableOrderingComposer({
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

  ColumnOrderings<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get courseCode => $composableBuilder(
    column: $table.courseCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get semesterKey => $composableBuilder(
    column: $table.semesterKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get participantsJson => $composableBuilder(
    column: $table.participantsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceDetailsJson => $composableBuilder(
    column: $table.sourceDetailsJson,
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

class $$CourseSeriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CourseSeriesTable> {
  $$CourseSeriesTableAnnotationComposer({
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

  GeneratedColumn<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get courseCode => $composableBuilder(
    column: $table.courseCode,
    builder: (column) => column,
  );

  GeneratedColumn<String> get semesterKey => $composableBuilder(
    column: $table.semesterKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get participantsJson => $composableBuilder(
    column: $table.participantsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceDetailsJson => $composableBuilder(
    column: $table.sourceDetailsJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

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

class $$CourseSeriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CourseSeriesTable,
          CourseSery,
          $$CourseSeriesTableFilterComposer,
          $$CourseSeriesTableOrderingComposer,
          $$CourseSeriesTableAnnotationComposer,
          $$CourseSeriesTableCreateCompanionBuilder,
          $$CourseSeriesTableUpdateCompanionBuilder,
          (CourseSery, $$CourseSeriesTableReferences),
          CourseSery,
          PrefetchHooks Function({bool accountId})
        > {
  $$CourseSeriesTableTableManager(_$AppDatabase db, $CourseSeriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CourseSeriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CourseSeriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CourseSeriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> externalId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> courseCode = const Value.absent(),
                Value<String> semesterKey = const Value.absent(),
                Value<String> participantsJson = const Value.absent(),
                Value<String> sourceDetailsJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CourseSeriesCompanion(
                id: id,
                accountId: accountId,
                source: source,
                externalId: externalId,
                title: title,
                courseCode: courseCode,
                semesterKey: semesterKey,
                participantsJson: participantsJson,
                sourceDetailsJson: sourceDetailsJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String source,
                required String externalId,
                required String title,
                Value<String?> courseCode = const Value.absent(),
                required String semesterKey,
                Value<String> participantsJson = const Value.absent(),
                required String sourceDetailsJson,
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => CourseSeriesCompanion.insert(
                id: id,
                accountId: accountId,
                source: source,
                externalId: externalId,
                title: title,
                courseCode: courseCode,
                semesterKey: semesterKey,
                participantsJson: participantsJson,
                sourceDetailsJson: sourceDetailsJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CourseSeriesTableReferences(db, table, e),
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
                                referencedTable: $$CourseSeriesTableReferences
                                    ._accountIdTable(db),
                                referencedColumn: $$CourseSeriesTableReferences
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

typedef $$CourseSeriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CourseSeriesTable,
      CourseSery,
      $$CourseSeriesTableFilterComposer,
      $$CourseSeriesTableOrderingComposer,
      $$CourseSeriesTableAnnotationComposer,
      $$CourseSeriesTableCreateCompanionBuilder,
      $$CourseSeriesTableUpdateCompanionBuilder,
      (CourseSery, $$CourseSeriesTableReferences),
      CourseSery,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$CalendarEventSeriesTableCreateCompanionBuilder =
    CalendarEventSeriesCompanion Function({
      required String id,
      required String accountId,
      required String title,
      Value<String?> description,
      required String eventType,
      required String timezone,
      required int startAt,
      required int durationMinutes,
      required String recurrenceJson,
      Value<String?> effectiveFrom,
      Value<String?> effectiveThrough,
      Value<String?> locationName,
      Value<String> completionPolicy,
      Value<bool> deleted,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$CalendarEventSeriesTableUpdateCompanionBuilder =
    CalendarEventSeriesCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> title,
      Value<String?> description,
      Value<String> eventType,
      Value<String> timezone,
      Value<int> startAt,
      Value<int> durationMinutes,
      Value<String> recurrenceJson,
      Value<String?> effectiveFrom,
      Value<String?> effectiveThrough,
      Value<String?> locationName,
      Value<String> completionPolicy,
      Value<bool> deleted,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$CalendarEventSeriesTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $CalendarEventSeriesTable,
          CalendarEventSery
        > {
  $$CalendarEventSeriesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('calendar_event_series__account_id__local_accounts__id');

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

  static MultiTypedResultKey<$CalendarEventsTable, List<CalendarEvent>>
  _calendarEventsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.calendarEvents,
    aliasName: 'calendar_event_series__id__calendar_events__personal_series_id',
  );

  $$CalendarEventsTableProcessedTableManager get calendarEventsRefs {
    final manager = $$CalendarEventsTableTableManager($_db, $_db.calendarEvents)
        .filter(
          (f) => f.personalSeriesId.id.sqlEquals($_itemColumn<String>('id')!),
        );

    final cache = $_typedResult.readTableOrNull(_calendarEventsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $CalendarEventOccurrenceExceptionsTable,
    List<CalendarEventOccurrenceException>
  >
  _calendarEventOccurrenceExceptionsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.calendarEventOccurrenceExceptions,
    aliasName:
        'calendar_event_series__id__calendar_event_occurrence_exceptions__series_id',
  );

  $$CalendarEventOccurrenceExceptionsTableProcessedTableManager
  get calendarEventOccurrenceExceptionsRefs {
    final manager = $$CalendarEventOccurrenceExceptionsTableTableManager(
      $_db,
      $_db.calendarEventOccurrenceExceptions,
    ).filter((f) => f.seriesId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _calendarEventOccurrenceExceptionsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$CalendarEventSeriesTableFilterComposer
    extends Composer<_$AppDatabase, $CalendarEventSeriesTable> {
  $$CalendarEventSeriesTableFilterComposer({
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

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get eventType => $composableBuilder(
    column: $table.eventType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get timezone => $composableBuilder(
    column: $table.timezone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startAt => $composableBuilder(
    column: $table.startAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMinutes => $composableBuilder(
    column: $table.durationMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recurrenceJson => $composableBuilder(
    column: $table.recurrenceJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get effectiveFrom => $composableBuilder(
    column: $table.effectiveFrom,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get effectiveThrough => $composableBuilder(
    column: $table.effectiveThrough,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get locationName => $composableBuilder(
    column: $table.locationName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get completionPolicy => $composableBuilder(
    column: $table.completionPolicy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
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

  Expression<bool> calendarEventsRefs(
    Expression<bool> Function($$CalendarEventsTableFilterComposer f) f,
  ) {
    final $$CalendarEventsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.personalSeriesId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableFilterComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> calendarEventOccurrenceExceptionsRefs(
    Expression<bool> Function(
      $$CalendarEventOccurrenceExceptionsTableFilterComposer f,
    )
    f,
  ) {
    final $$CalendarEventOccurrenceExceptionsTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.calendarEventOccurrenceExceptions,
          getReferencedColumn: (t) => t.seriesId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CalendarEventOccurrenceExceptionsTableFilterComposer(
                $db: $db,
                $table: $db.calendarEventOccurrenceExceptions,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$CalendarEventSeriesTableOrderingComposer
    extends Composer<_$AppDatabase, $CalendarEventSeriesTable> {
  $$CalendarEventSeriesTableOrderingComposer({
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

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get eventType => $composableBuilder(
    column: $table.eventType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get timezone => $composableBuilder(
    column: $table.timezone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startAt => $composableBuilder(
    column: $table.startAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMinutes => $composableBuilder(
    column: $table.durationMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recurrenceJson => $composableBuilder(
    column: $table.recurrenceJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get effectiveFrom => $composableBuilder(
    column: $table.effectiveFrom,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get effectiveThrough => $composableBuilder(
    column: $table.effectiveThrough,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get locationName => $composableBuilder(
    column: $table.locationName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get completionPolicy => $composableBuilder(
    column: $table.completionPolicy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
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

class $$CalendarEventSeriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CalendarEventSeriesTable> {
  $$CalendarEventSeriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<String> get eventType =>
      $composableBuilder(column: $table.eventType, builder: (column) => column);

  GeneratedColumn<String> get timezone =>
      $composableBuilder(column: $table.timezone, builder: (column) => column);

  GeneratedColumn<int> get startAt =>
      $composableBuilder(column: $table.startAt, builder: (column) => column);

  GeneratedColumn<int> get durationMinutes => $composableBuilder(
    column: $table.durationMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get recurrenceJson => $composableBuilder(
    column: $table.recurrenceJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get effectiveFrom => $composableBuilder(
    column: $table.effectiveFrom,
    builder: (column) => column,
  );

  GeneratedColumn<String> get effectiveThrough => $composableBuilder(
    column: $table.effectiveThrough,
    builder: (column) => column,
  );

  GeneratedColumn<String> get locationName => $composableBuilder(
    column: $table.locationName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get completionPolicy => $composableBuilder(
    column: $table.completionPolicy,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

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

  Expression<T> calendarEventsRefs<T extends Object>(
    Expression<T> Function($$CalendarEventsTableAnnotationComposer a) f,
  ) {
    final $$CalendarEventsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.personalSeriesId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableAnnotationComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> calendarEventOccurrenceExceptionsRefs<T extends Object>(
    Expression<T> Function(
      $$CalendarEventOccurrenceExceptionsTableAnnotationComposer a,
    )
    f,
  ) {
    final $$CalendarEventOccurrenceExceptionsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.calendarEventOccurrenceExceptions,
          getReferencedColumn: (t) => t.seriesId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CalendarEventOccurrenceExceptionsTableAnnotationComposer(
                $db: $db,
                $table: $db.calendarEventOccurrenceExceptions,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$CalendarEventSeriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CalendarEventSeriesTable,
          CalendarEventSery,
          $$CalendarEventSeriesTableFilterComposer,
          $$CalendarEventSeriesTableOrderingComposer,
          $$CalendarEventSeriesTableAnnotationComposer,
          $$CalendarEventSeriesTableCreateCompanionBuilder,
          $$CalendarEventSeriesTableUpdateCompanionBuilder,
          (CalendarEventSery, $$CalendarEventSeriesTableReferences),
          CalendarEventSery,
          PrefetchHooks Function({
            bool accountId,
            bool calendarEventsRefs,
            bool calendarEventOccurrenceExceptionsRefs,
          })
        > {
  $$CalendarEventSeriesTableTableManager(
    _$AppDatabase db,
    $CalendarEventSeriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CalendarEventSeriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CalendarEventSeriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CalendarEventSeriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<String> eventType = const Value.absent(),
                Value<String> timezone = const Value.absent(),
                Value<int> startAt = const Value.absent(),
                Value<int> durationMinutes = const Value.absent(),
                Value<String> recurrenceJson = const Value.absent(),
                Value<String?> effectiveFrom = const Value.absent(),
                Value<String?> effectiveThrough = const Value.absent(),
                Value<String?> locationName = const Value.absent(),
                Value<String> completionPolicy = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventSeriesCompanion(
                id: id,
                accountId: accountId,
                title: title,
                description: description,
                eventType: eventType,
                timezone: timezone,
                startAt: startAt,
                durationMinutes: durationMinutes,
                recurrenceJson: recurrenceJson,
                effectiveFrom: effectiveFrom,
                effectiveThrough: effectiveThrough,
                locationName: locationName,
                completionPolicy: completionPolicy,
                deleted: deleted,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String title,
                Value<String?> description = const Value.absent(),
                required String eventType,
                required String timezone,
                required int startAt,
                required int durationMinutes,
                required String recurrenceJson,
                Value<String?> effectiveFrom = const Value.absent(),
                Value<String?> effectiveThrough = const Value.absent(),
                Value<String?> locationName = const Value.absent(),
                Value<String> completionPolicy = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventSeriesCompanion.insert(
                id: id,
                accountId: accountId,
                title: title,
                description: description,
                eventType: eventType,
                timezone: timezone,
                startAt: startAt,
                durationMinutes: durationMinutes,
                recurrenceJson: recurrenceJson,
                effectiveFrom: effectiveFrom,
                effectiveThrough: effectiveThrough,
                locationName: locationName,
                completionPolicy: completionPolicy,
                deleted: deleted,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CalendarEventSeriesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                accountId = false,
                calendarEventsRefs = false,
                calendarEventOccurrenceExceptionsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (calendarEventsRefs) db.calendarEvents,
                    if (calendarEventOccurrenceExceptionsRefs)
                      db.calendarEventOccurrenceExceptions,
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
                                        $$CalendarEventSeriesTableReferences
                                            ._accountIdTable(db),
                                    referencedColumn:
                                        $$CalendarEventSeriesTableReferences
                                            ._accountIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (calendarEventsRefs)
                        await $_getPrefetchedData<
                          CalendarEventSery,
                          $CalendarEventSeriesTable,
                          CalendarEvent
                        >(
                          currentTable: table,
                          referencedTable: $$CalendarEventSeriesTableReferences
                              ._calendarEventsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CalendarEventSeriesTableReferences(
                                db,
                                table,
                                p0,
                              ).calendarEventsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.personalSeriesId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (calendarEventOccurrenceExceptionsRefs)
                        await $_getPrefetchedData<
                          CalendarEventSery,
                          $CalendarEventSeriesTable,
                          CalendarEventOccurrenceException
                        >(
                          currentTable: table,
                          referencedTable: $$CalendarEventSeriesTableReferences
                              ._calendarEventOccurrenceExceptionsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CalendarEventSeriesTableReferences(
                                db,
                                table,
                                p0,
                              ).calendarEventOccurrenceExceptionsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.seriesId == item.id,
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

typedef $$CalendarEventSeriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CalendarEventSeriesTable,
      CalendarEventSery,
      $$CalendarEventSeriesTableFilterComposer,
      $$CalendarEventSeriesTableOrderingComposer,
      $$CalendarEventSeriesTableAnnotationComposer,
      $$CalendarEventSeriesTableCreateCompanionBuilder,
      $$CalendarEventSeriesTableUpdateCompanionBuilder,
      (CalendarEventSery, $$CalendarEventSeriesTableReferences),
      CalendarEventSery,
      PrefetchHooks Function({
        bool accountId,
        bool calendarEventsRefs,
        bool calendarEventOccurrenceExceptionsRefs,
      })
    >;
typedef $$CalendarEventsTableCreateCompanionBuilder =
    CalendarEventsCompanion Function({
      required String id,
      required String accountId,
      required String source,
      Value<String?> externalId,
      Value<String?> sourceSeriesExternalId,
      Value<String?> personalSeriesId,
      Value<String?> occurrenceKey,
      required String title,
      Value<String?> description,
      required String type,
      Value<String> status,
      Value<int?> startAt,
      Value<int?> endAt,
      required bool allDay,
      Value<String?> startDate,
      Value<String?> endDateExclusive,
      required String timezone,
      Value<String?> locationName,
      Value<String?> buildingName,
      Value<String?> campusName,
      Value<String> participantsJson,
      Value<String> sourceDetailsJson,
      Value<String> importance,
      Value<String> completionPolicy,
      Value<int?> completedAt,
      Value<String?> color,
      Value<String> tagsJson,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<int> rowid,
    });
typedef $$CalendarEventsTableUpdateCompanionBuilder =
    CalendarEventsCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> source,
      Value<String?> externalId,
      Value<String?> sourceSeriesExternalId,
      Value<String?> personalSeriesId,
      Value<String?> occurrenceKey,
      Value<String> title,
      Value<String?> description,
      Value<String> type,
      Value<String> status,
      Value<int?> startAt,
      Value<int?> endAt,
      Value<bool> allDay,
      Value<String?> startDate,
      Value<String?> endDateExclusive,
      Value<String> timezone,
      Value<String?> locationName,
      Value<String?> buildingName,
      Value<String?> campusName,
      Value<String> participantsJson,
      Value<String> sourceDetailsJson,
      Value<String> importance,
      Value<String> completionPolicy,
      Value<int?> completedAt,
      Value<String?> color,
      Value<String> tagsJson,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<int> rowid,
    });

final class $$CalendarEventsTableReferences
    extends BaseReferences<_$AppDatabase, $CalendarEventsTable, CalendarEvent> {
  $$CalendarEventsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('calendar_events__account_id__local_accounts__id');

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

  static $CalendarEventSeriesTable _personalSeriesIdTable(_$AppDatabase db) =>
      db.calendarEventSeries.createAlias(
        'calendar_events__personal_series_id__calendar_event_series__id',
      );

  $$CalendarEventSeriesTableProcessedTableManager? get personalSeriesId {
    final $_column = $_itemColumn<String>('personal_series_id');
    if ($_column == null) return null;
    final manager = $$CalendarEventSeriesTableTableManager(
      $_db,
      $_db.calendarEventSeries,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_personalSeriesIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$UserOverlaysTable, List<UserOverlay>>
  _userOverlaysRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.userOverlays,
    aliasName: 'calendar_events__id__user_overlays__event_id',
  );

  $$UserOverlaysTableProcessedTableManager get userOverlaysRefs {
    final manager = $$UserOverlaysTableTableManager(
      $_db,
      $_db.userOverlays,
    ).filter((f) => f.eventId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_userOverlaysRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$TaskEventLinksTable, List<TaskEventLink>>
  _taskEventLinksRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.taskEventLinks,
    aliasName: 'calendar_events__id__task_event_links__event_id',
  );

  $$TaskEventLinksTableProcessedTableManager get taskEventLinksRefs {
    final manager = $$TaskEventLinksTableTableManager(
      $_db,
      $_db.taskEventLinks,
    ).filter((f) => f.eventId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_taskEventLinksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ScheduleRelationsTable, List<ScheduleRelation>>
  _leftEventRelationsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.scheduleRelations,
    aliasName: 'calendar_events__id__schedule_relations__left_event_id',
  );

  $$ScheduleRelationsTableProcessedTableManager get leftEventRelations {
    final manager = $$ScheduleRelationsTableTableManager(
      $_db,
      $_db.scheduleRelations,
    ).filter((f) => f.leftEventId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_leftEventRelationsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ScheduleRelationsTable, List<ScheduleRelation>>
  _rightEventRelationsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.scheduleRelations,
    aliasName: 'calendar_events__id__schedule_relations__right_event_id',
  );

  $$ScheduleRelationsTableProcessedTableManager get rightEventRelations {
    final manager = $$ScheduleRelationsTableTableManager(
      $_db,
      $_db.scheduleRelations,
    ).filter((f) => f.rightEventId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _rightEventRelationsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$RemindersTable, List<Reminder>>
  _remindersRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.reminders,
    aliasName: 'calendar_events__id__reminders__event_id',
  );

  $$RemindersTableProcessedTableManager get remindersRefs {
    final manager = $$RemindersTableTableManager(
      $_db,
      $_db.reminders,
    ).filter((f) => f.eventId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_remindersRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$CalendarEventsTableFilterComposer
    extends Composer<_$AppDatabase, $CalendarEventsTable> {
  $$CalendarEventsTableFilterComposer({
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

  ColumnFilters<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceSeriesExternalId => $composableBuilder(
    column: $table.sourceSeriesExternalId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get occurrenceKey => $composableBuilder(
    column: $table.occurrenceKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startAt => $composableBuilder(
    column: $table.startAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endAt => $composableBuilder(
    column: $table.endAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get allDay => $composableBuilder(
    column: $table.allDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get startDate => $composableBuilder(
    column: $table.startDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get endDateExclusive => $composableBuilder(
    column: $table.endDateExclusive,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get timezone => $composableBuilder(
    column: $table.timezone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get locationName => $composableBuilder(
    column: $table.locationName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get buildingName => $composableBuilder(
    column: $table.buildingName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get campusName => $composableBuilder(
    column: $table.campusName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get participantsJson => $composableBuilder(
    column: $table.participantsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceDetailsJson => $composableBuilder(
    column: $table.sourceDetailsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get importance => $composableBuilder(
    column: $table.importance,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get completionPolicy => $composableBuilder(
    column: $table.completionPolicy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
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

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
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

  $$CalendarEventSeriesTableFilterComposer get personalSeriesId {
    final $$CalendarEventSeriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.personalSeriesId,
      referencedTable: $db.calendarEventSeries,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventSeriesTableFilterComposer(
            $db: $db,
            $table: $db.calendarEventSeries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> userOverlaysRefs(
    Expression<bool> Function($$UserOverlaysTableFilterComposer f) f,
  ) {
    final $$UserOverlaysTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.userOverlays,
      getReferencedColumn: (t) => t.eventId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$UserOverlaysTableFilterComposer(
            $db: $db,
            $table: $db.userOverlays,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> taskEventLinksRefs(
    Expression<bool> Function($$TaskEventLinksTableFilterComposer f) f,
  ) {
    final $$TaskEventLinksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskEventLinks,
      getReferencedColumn: (t) => t.eventId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskEventLinksTableFilterComposer(
            $db: $db,
            $table: $db.taskEventLinks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> leftEventRelations(
    Expression<bool> Function($$ScheduleRelationsTableFilterComposer f) f,
  ) {
    final $$ScheduleRelationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scheduleRelations,
      getReferencedColumn: (t) => t.leftEventId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScheduleRelationsTableFilterComposer(
            $db: $db,
            $table: $db.scheduleRelations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> rightEventRelations(
    Expression<bool> Function($$ScheduleRelationsTableFilterComposer f) f,
  ) {
    final $$ScheduleRelationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scheduleRelations,
      getReferencedColumn: (t) => t.rightEventId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScheduleRelationsTableFilterComposer(
            $db: $db,
            $table: $db.scheduleRelations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> remindersRefs(
    Expression<bool> Function($$RemindersTableFilterComposer f) f,
  ) {
    final $$RemindersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.reminders,
      getReferencedColumn: (t) => t.eventId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RemindersTableFilterComposer(
            $db: $db,
            $table: $db.reminders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$CalendarEventsTableOrderingComposer
    extends Composer<_$AppDatabase, $CalendarEventsTable> {
  $$CalendarEventsTableOrderingComposer({
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

  ColumnOrderings<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceSeriesExternalId => $composableBuilder(
    column: $table.sourceSeriesExternalId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get occurrenceKey => $composableBuilder(
    column: $table.occurrenceKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startAt => $composableBuilder(
    column: $table.startAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endAt => $composableBuilder(
    column: $table.endAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get allDay => $composableBuilder(
    column: $table.allDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get startDate => $composableBuilder(
    column: $table.startDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get endDateExclusive => $composableBuilder(
    column: $table.endDateExclusive,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get timezone => $composableBuilder(
    column: $table.timezone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get locationName => $composableBuilder(
    column: $table.locationName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get buildingName => $composableBuilder(
    column: $table.buildingName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get campusName => $composableBuilder(
    column: $table.campusName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get participantsJson => $composableBuilder(
    column: $table.participantsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceDetailsJson => $composableBuilder(
    column: $table.sourceDetailsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get importance => $composableBuilder(
    column: $table.importance,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get completionPolicy => $composableBuilder(
    column: $table.completionPolicy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
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

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
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

  $$CalendarEventSeriesTableOrderingComposer get personalSeriesId {
    final $$CalendarEventSeriesTableOrderingComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.personalSeriesId,
          referencedTable: $db.calendarEventSeries,
          getReferencedColumn: (t) => t.id,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CalendarEventSeriesTableOrderingComposer(
                $db: $db,
                $table: $db.calendarEventSeries,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$CalendarEventsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CalendarEventsTable> {
  $$CalendarEventsTableAnnotationComposer({
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

  GeneratedColumn<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceSeriesExternalId => $composableBuilder(
    column: $table.sourceSeriesExternalId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get occurrenceKey => $composableBuilder(
    column: $table.occurrenceKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get startAt =>
      $composableBuilder(column: $table.startAt, builder: (column) => column);

  GeneratedColumn<int> get endAt =>
      $composableBuilder(column: $table.endAt, builder: (column) => column);

  GeneratedColumn<bool> get allDay =>
      $composableBuilder(column: $table.allDay, builder: (column) => column);

  GeneratedColumn<String> get startDate =>
      $composableBuilder(column: $table.startDate, builder: (column) => column);

  GeneratedColumn<String> get endDateExclusive => $composableBuilder(
    column: $table.endDateExclusive,
    builder: (column) => column,
  );

  GeneratedColumn<String> get timezone =>
      $composableBuilder(column: $table.timezone, builder: (column) => column);

  GeneratedColumn<String> get locationName => $composableBuilder(
    column: $table.locationName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get buildingName => $composableBuilder(
    column: $table.buildingName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get campusName => $composableBuilder(
    column: $table.campusName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get participantsJson => $composableBuilder(
    column: $table.participantsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceDetailsJson => $composableBuilder(
    column: $table.sourceDetailsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get importance => $composableBuilder(
    column: $table.importance,
    builder: (column) => column,
  );

  GeneratedColumn<String> get completionPolicy => $composableBuilder(
    column: $table.completionPolicy,
    builder: (column) => column,
  );

  GeneratedColumn<int> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

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

  $$CalendarEventSeriesTableAnnotationComposer get personalSeriesId {
    final $$CalendarEventSeriesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.personalSeriesId,
          referencedTable: $db.calendarEventSeries,
          getReferencedColumn: (t) => t.id,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CalendarEventSeriesTableAnnotationComposer(
                $db: $db,
                $table: $db.calendarEventSeries,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }

  Expression<T> userOverlaysRefs<T extends Object>(
    Expression<T> Function($$UserOverlaysTableAnnotationComposer a) f,
  ) {
    final $$UserOverlaysTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.userOverlays,
      getReferencedColumn: (t) => t.eventId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$UserOverlaysTableAnnotationComposer(
            $db: $db,
            $table: $db.userOverlays,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> taskEventLinksRefs<T extends Object>(
    Expression<T> Function($$TaskEventLinksTableAnnotationComposer a) f,
  ) {
    final $$TaskEventLinksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskEventLinks,
      getReferencedColumn: (t) => t.eventId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskEventLinksTableAnnotationComposer(
            $db: $db,
            $table: $db.taskEventLinks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> leftEventRelations<T extends Object>(
    Expression<T> Function($$ScheduleRelationsTableAnnotationComposer a) f,
  ) {
    final $$ScheduleRelationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.scheduleRelations,
          getReferencedColumn: (t) => t.leftEventId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ScheduleRelationsTableAnnotationComposer(
                $db: $db,
                $table: $db.scheduleRelations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> rightEventRelations<T extends Object>(
    Expression<T> Function($$ScheduleRelationsTableAnnotationComposer a) f,
  ) {
    final $$ScheduleRelationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.scheduleRelations,
          getReferencedColumn: (t) => t.rightEventId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ScheduleRelationsTableAnnotationComposer(
                $db: $db,
                $table: $db.scheduleRelations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> remindersRefs<T extends Object>(
    Expression<T> Function($$RemindersTableAnnotationComposer a) f,
  ) {
    final $$RemindersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.reminders,
      getReferencedColumn: (t) => t.eventId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RemindersTableAnnotationComposer(
            $db: $db,
            $table: $db.reminders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$CalendarEventsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CalendarEventsTable,
          CalendarEvent,
          $$CalendarEventsTableFilterComposer,
          $$CalendarEventsTableOrderingComposer,
          $$CalendarEventsTableAnnotationComposer,
          $$CalendarEventsTableCreateCompanionBuilder,
          $$CalendarEventsTableUpdateCompanionBuilder,
          (CalendarEvent, $$CalendarEventsTableReferences),
          CalendarEvent,
          PrefetchHooks Function({
            bool accountId,
            bool personalSeriesId,
            bool userOverlaysRefs,
            bool taskEventLinksRefs,
            bool leftEventRelations,
            bool rightEventRelations,
            bool remindersRefs,
          })
        > {
  $$CalendarEventsTableTableManager(
    _$AppDatabase db,
    $CalendarEventsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CalendarEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CalendarEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CalendarEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> externalId = const Value.absent(),
                Value<String?> sourceSeriesExternalId = const Value.absent(),
                Value<String?> personalSeriesId = const Value.absent(),
                Value<String?> occurrenceKey = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int?> startAt = const Value.absent(),
                Value<int?> endAt = const Value.absent(),
                Value<bool> allDay = const Value.absent(),
                Value<String?> startDate = const Value.absent(),
                Value<String?> endDateExclusive = const Value.absent(),
                Value<String> timezone = const Value.absent(),
                Value<String?> locationName = const Value.absent(),
                Value<String?> buildingName = const Value.absent(),
                Value<String?> campusName = const Value.absent(),
                Value<String> participantsJson = const Value.absent(),
                Value<String> sourceDetailsJson = const Value.absent(),
                Value<String> importance = const Value.absent(),
                Value<String> completionPolicy = const Value.absent(),
                Value<int?> completedAt = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventsCompanion(
                id: id,
                accountId: accountId,
                source: source,
                externalId: externalId,
                sourceSeriesExternalId: sourceSeriesExternalId,
                personalSeriesId: personalSeriesId,
                occurrenceKey: occurrenceKey,
                title: title,
                description: description,
                type: type,
                status: status,
                startAt: startAt,
                endAt: endAt,
                allDay: allDay,
                startDate: startDate,
                endDateExclusive: endDateExclusive,
                timezone: timezone,
                locationName: locationName,
                buildingName: buildingName,
                campusName: campusName,
                participantsJson: participantsJson,
                sourceDetailsJson: sourceDetailsJson,
                importance: importance,
                completionPolicy: completionPolicy,
                completedAt: completedAt,
                color: color,
                tagsJson: tagsJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String source,
                Value<String?> externalId = const Value.absent(),
                Value<String?> sourceSeriesExternalId = const Value.absent(),
                Value<String?> personalSeriesId = const Value.absent(),
                Value<String?> occurrenceKey = const Value.absent(),
                required String title,
                Value<String?> description = const Value.absent(),
                required String type,
                Value<String> status = const Value.absent(),
                Value<int?> startAt = const Value.absent(),
                Value<int?> endAt = const Value.absent(),
                required bool allDay,
                Value<String?> startDate = const Value.absent(),
                Value<String?> endDateExclusive = const Value.absent(),
                required String timezone,
                Value<String?> locationName = const Value.absent(),
                Value<String?> buildingName = const Value.absent(),
                Value<String?> campusName = const Value.absent(),
                Value<String> participantsJson = const Value.absent(),
                Value<String> sourceDetailsJson = const Value.absent(),
                Value<String> importance = const Value.absent(),
                Value<String> completionPolicy = const Value.absent(),
                Value<int?> completedAt = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventsCompanion.insert(
                id: id,
                accountId: accountId,
                source: source,
                externalId: externalId,
                sourceSeriesExternalId: sourceSeriesExternalId,
                personalSeriesId: personalSeriesId,
                occurrenceKey: occurrenceKey,
                title: title,
                description: description,
                type: type,
                status: status,
                startAt: startAt,
                endAt: endAt,
                allDay: allDay,
                startDate: startDate,
                endDateExclusive: endDateExclusive,
                timezone: timezone,
                locationName: locationName,
                buildingName: buildingName,
                campusName: campusName,
                participantsJson: participantsJson,
                sourceDetailsJson: sourceDetailsJson,
                importance: importance,
                completionPolicy: completionPolicy,
                completedAt: completedAt,
                color: color,
                tagsJson: tagsJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CalendarEventsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                accountId = false,
                personalSeriesId = false,
                userOverlaysRefs = false,
                taskEventLinksRefs = false,
                leftEventRelations = false,
                rightEventRelations = false,
                remindersRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (userOverlaysRefs) db.userOverlays,
                    if (taskEventLinksRefs) db.taskEventLinks,
                    if (leftEventRelations) db.scheduleRelations,
                    if (rightEventRelations) db.scheduleRelations,
                    if (remindersRefs) db.reminders,
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
                                        $$CalendarEventsTableReferences
                                            ._accountIdTable(db),
                                    referencedColumn:
                                        $$CalendarEventsTableReferences
                                            ._accountIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (personalSeriesId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.personalSeriesId,
                                    referencedTable:
                                        $$CalendarEventsTableReferences
                                            ._personalSeriesIdTable(db),
                                    referencedColumn:
                                        $$CalendarEventsTableReferences
                                            ._personalSeriesIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (userOverlaysRefs)
                        await $_getPrefetchedData<
                          CalendarEvent,
                          $CalendarEventsTable,
                          UserOverlay
                        >(
                          currentTable: table,
                          referencedTable: $$CalendarEventsTableReferences
                              ._userOverlaysRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CalendarEventsTableReferences(
                                db,
                                table,
                                p0,
                              ).userOverlaysRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.eventId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (taskEventLinksRefs)
                        await $_getPrefetchedData<
                          CalendarEvent,
                          $CalendarEventsTable,
                          TaskEventLink
                        >(
                          currentTable: table,
                          referencedTable: $$CalendarEventsTableReferences
                              ._taskEventLinksRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CalendarEventsTableReferences(
                                db,
                                table,
                                p0,
                              ).taskEventLinksRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.eventId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (leftEventRelations)
                        await $_getPrefetchedData<
                          CalendarEvent,
                          $CalendarEventsTable,
                          ScheduleRelation
                        >(
                          currentTable: table,
                          referencedTable: $$CalendarEventsTableReferences
                              ._leftEventRelationsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CalendarEventsTableReferences(
                                db,
                                table,
                                p0,
                              ).leftEventRelations,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.leftEventId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (rightEventRelations)
                        await $_getPrefetchedData<
                          CalendarEvent,
                          $CalendarEventsTable,
                          ScheduleRelation
                        >(
                          currentTable: table,
                          referencedTable: $$CalendarEventsTableReferences
                              ._rightEventRelationsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CalendarEventsTableReferences(
                                db,
                                table,
                                p0,
                              ).rightEventRelations,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.rightEventId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (remindersRefs)
                        await $_getPrefetchedData<
                          CalendarEvent,
                          $CalendarEventsTable,
                          Reminder
                        >(
                          currentTable: table,
                          referencedTable: $$CalendarEventsTableReferences
                              ._remindersRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CalendarEventsTableReferences(
                                db,
                                table,
                                p0,
                              ).remindersRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.eventId == item.id,
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

typedef $$CalendarEventsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CalendarEventsTable,
      CalendarEvent,
      $$CalendarEventsTableFilterComposer,
      $$CalendarEventsTableOrderingComposer,
      $$CalendarEventsTableAnnotationComposer,
      $$CalendarEventsTableCreateCompanionBuilder,
      $$CalendarEventsTableUpdateCompanionBuilder,
      (CalendarEvent, $$CalendarEventsTableReferences),
      CalendarEvent,
      PrefetchHooks Function({
        bool accountId,
        bool personalSeriesId,
        bool userOverlaysRefs,
        bool taskEventLinksRefs,
        bool leftEventRelations,
        bool rightEventRelations,
        bool remindersRefs,
      })
    >;
typedef $$CalendarEventOccurrenceExceptionsTableCreateCompanionBuilder =
    CalendarEventOccurrenceExceptionsCompanion Function({
      required String id,
      required String accountId,
      required String seriesId,
      required String occurrenceKey,
      required String kind,
      required String overrideJson,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$CalendarEventOccurrenceExceptionsTableUpdateCompanionBuilder =
    CalendarEventOccurrenceExceptionsCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> seriesId,
      Value<String> occurrenceKey,
      Value<String> kind,
      Value<String> overrideJson,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$CalendarEventOccurrenceExceptionsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $CalendarEventOccurrenceExceptionsTable,
          CalendarEventOccurrenceException
        > {
  $$CalendarEventOccurrenceExceptionsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) =>
      db.localAccounts.createAlias(
        'calendar_event_occurrence_exceptions__account_id__local_accounts__id',
      );

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

  static $CalendarEventSeriesTable _seriesIdTable(
    _$AppDatabase db,
  ) => db.calendarEventSeries.createAlias(
    'calendar_event_occurrence_exceptions__series_id__calendar_event_series__id',
  );

  $$CalendarEventSeriesTableProcessedTableManager get seriesId {
    final $_column = $_itemColumn<String>('series_id')!;

    final manager = $$CalendarEventSeriesTableTableManager(
      $_db,
      $_db.calendarEventSeries,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_seriesIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CalendarEventOccurrenceExceptionsTableFilterComposer
    extends Composer<_$AppDatabase, $CalendarEventOccurrenceExceptionsTable> {
  $$CalendarEventOccurrenceExceptionsTableFilterComposer({
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

  ColumnFilters<String> get occurrenceKey => $composableBuilder(
    column: $table.occurrenceKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get overrideJson => $composableBuilder(
    column: $table.overrideJson,
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

  $$CalendarEventSeriesTableFilterComposer get seriesId {
    final $$CalendarEventSeriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.seriesId,
      referencedTable: $db.calendarEventSeries,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventSeriesTableFilterComposer(
            $db: $db,
            $table: $db.calendarEventSeries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CalendarEventOccurrenceExceptionsTableOrderingComposer
    extends Composer<_$AppDatabase, $CalendarEventOccurrenceExceptionsTable> {
  $$CalendarEventOccurrenceExceptionsTableOrderingComposer({
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

  ColumnOrderings<String> get occurrenceKey => $composableBuilder(
    column: $table.occurrenceKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get overrideJson => $composableBuilder(
    column: $table.overrideJson,
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

  $$CalendarEventSeriesTableOrderingComposer get seriesId {
    final $$CalendarEventSeriesTableOrderingComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.seriesId,
          referencedTable: $db.calendarEventSeries,
          getReferencedColumn: (t) => t.id,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CalendarEventSeriesTableOrderingComposer(
                $db: $db,
                $table: $db.calendarEventSeries,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$CalendarEventOccurrenceExceptionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CalendarEventOccurrenceExceptionsTable> {
  $$CalendarEventOccurrenceExceptionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get occurrenceKey => $composableBuilder(
    column: $table.occurrenceKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get overrideJson => $composableBuilder(
    column: $table.overrideJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

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

  $$CalendarEventSeriesTableAnnotationComposer get seriesId {
    final $$CalendarEventSeriesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.seriesId,
          referencedTable: $db.calendarEventSeries,
          getReferencedColumn: (t) => t.id,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CalendarEventSeriesTableAnnotationComposer(
                $db: $db,
                $table: $db.calendarEventSeries,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$CalendarEventOccurrenceExceptionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CalendarEventOccurrenceExceptionsTable,
          CalendarEventOccurrenceException,
          $$CalendarEventOccurrenceExceptionsTableFilterComposer,
          $$CalendarEventOccurrenceExceptionsTableOrderingComposer,
          $$CalendarEventOccurrenceExceptionsTableAnnotationComposer,
          $$CalendarEventOccurrenceExceptionsTableCreateCompanionBuilder,
          $$CalendarEventOccurrenceExceptionsTableUpdateCompanionBuilder,
          (
            CalendarEventOccurrenceException,
            $$CalendarEventOccurrenceExceptionsTableReferences,
          ),
          CalendarEventOccurrenceException,
          PrefetchHooks Function({bool accountId, bool seriesId})
        > {
  $$CalendarEventOccurrenceExceptionsTableTableManager(
    _$AppDatabase db,
    $CalendarEventOccurrenceExceptionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CalendarEventOccurrenceExceptionsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$CalendarEventOccurrenceExceptionsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CalendarEventOccurrenceExceptionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> seriesId = const Value.absent(),
                Value<String> occurrenceKey = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> overrideJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventOccurrenceExceptionsCompanion(
                id: id,
                accountId: accountId,
                seriesId: seriesId,
                occurrenceKey: occurrenceKey,
                kind: kind,
                overrideJson: overrideJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String seriesId,
                required String occurrenceKey,
                required String kind,
                required String overrideJson,
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventOccurrenceExceptionsCompanion.insert(
                id: id,
                accountId: accountId,
                seriesId: seriesId,
                occurrenceKey: occurrenceKey,
                kind: kind,
                overrideJson: overrideJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CalendarEventOccurrenceExceptionsTableReferences(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false, seriesId = false}) {
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
                                    $$CalendarEventOccurrenceExceptionsTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$CalendarEventOccurrenceExceptionsTableReferences
                                        ._accountIdTable(db)
                                        .id,
                              )
                              as T;
                    }
                    if (seriesId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.seriesId,
                                referencedTable:
                                    $$CalendarEventOccurrenceExceptionsTableReferences
                                        ._seriesIdTable(db),
                                referencedColumn:
                                    $$CalendarEventOccurrenceExceptionsTableReferences
                                        ._seriesIdTable(db)
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

typedef $$CalendarEventOccurrenceExceptionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CalendarEventOccurrenceExceptionsTable,
      CalendarEventOccurrenceException,
      $$CalendarEventOccurrenceExceptionsTableFilterComposer,
      $$CalendarEventOccurrenceExceptionsTableOrderingComposer,
      $$CalendarEventOccurrenceExceptionsTableAnnotationComposer,
      $$CalendarEventOccurrenceExceptionsTableCreateCompanionBuilder,
      $$CalendarEventOccurrenceExceptionsTableUpdateCompanionBuilder,
      (
        CalendarEventOccurrenceException,
        $$CalendarEventOccurrenceExceptionsTableReferences,
      ),
      CalendarEventOccurrenceException,
      PrefetchHooks Function({bool accountId, bool seriesId})
    >;
typedef $$UserOverlaysTableCreateCompanionBuilder =
    UserOverlaysCompanion Function({
      required String id,
      required String accountId,
      required String eventId,
      Value<String?> displayTitle,
      Value<String?> attendancePolicy,
      Value<String?> attendanceDecision,
      Value<int?> attendanceDecisionAt,
      Value<String?> attendanceNote,
      Value<String?> attendanceOutcome,
      Value<String?> listeningMode,
      Value<String?> listeningNote,
      Value<String?> importance,
      Value<String?> color,
      Value<bool?> hidden,
      Value<String?> userNotes,
      Value<String?> tagsJson,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$UserOverlaysTableUpdateCompanionBuilder =
    UserOverlaysCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> eventId,
      Value<String?> displayTitle,
      Value<String?> attendancePolicy,
      Value<String?> attendanceDecision,
      Value<int?> attendanceDecisionAt,
      Value<String?> attendanceNote,
      Value<String?> attendanceOutcome,
      Value<String?> listeningMode,
      Value<String?> listeningNote,
      Value<String?> importance,
      Value<String?> color,
      Value<bool?> hidden,
      Value<String?> userNotes,
      Value<String?> tagsJson,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$UserOverlaysTableReferences
    extends BaseReferences<_$AppDatabase, $UserOverlaysTable, UserOverlay> {
  $$UserOverlaysTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('user_overlays__account_id__local_accounts__id');

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

  static $CalendarEventsTable _eventIdTable(_$AppDatabase db) => db
      .calendarEvents
      .createAlias('user_overlays__event_id__calendar_events__id');

  $$CalendarEventsTableProcessedTableManager get eventId {
    final $_column = $_itemColumn<String>('event_id')!;

    final manager = $$CalendarEventsTableTableManager(
      $_db,
      $_db.calendarEvents,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_eventIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$UserOverlaysTableFilterComposer
    extends Composer<_$AppDatabase, $UserOverlaysTable> {
  $$UserOverlaysTableFilterComposer({
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

  ColumnFilters<String> get displayTitle => $composableBuilder(
    column: $table.displayTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attendancePolicy => $composableBuilder(
    column: $table.attendancePolicy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attendanceDecision => $composableBuilder(
    column: $table.attendanceDecision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attendanceDecisionAt => $composableBuilder(
    column: $table.attendanceDecisionAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attendanceNote => $composableBuilder(
    column: $table.attendanceNote,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attendanceOutcome => $composableBuilder(
    column: $table.attendanceOutcome,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get listeningMode => $composableBuilder(
    column: $table.listeningMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get listeningNote => $composableBuilder(
    column: $table.listeningNote,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get importance => $composableBuilder(
    column: $table.importance,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userNotes => $composableBuilder(
    column: $table.userNotes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
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

  $$CalendarEventsTableFilterComposer get eventId {
    final $$CalendarEventsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.eventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableFilterComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$UserOverlaysTableOrderingComposer
    extends Composer<_$AppDatabase, $UserOverlaysTable> {
  $$UserOverlaysTableOrderingComposer({
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

  ColumnOrderings<String> get displayTitle => $composableBuilder(
    column: $table.displayTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attendancePolicy => $composableBuilder(
    column: $table.attendancePolicy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attendanceDecision => $composableBuilder(
    column: $table.attendanceDecision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attendanceDecisionAt => $composableBuilder(
    column: $table.attendanceDecisionAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attendanceNote => $composableBuilder(
    column: $table.attendanceNote,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attendanceOutcome => $composableBuilder(
    column: $table.attendanceOutcome,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get listeningMode => $composableBuilder(
    column: $table.listeningMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get listeningNote => $composableBuilder(
    column: $table.listeningNote,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get importance => $composableBuilder(
    column: $table.importance,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userNotes => $composableBuilder(
    column: $table.userNotes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
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

  $$CalendarEventsTableOrderingComposer get eventId {
    final $$CalendarEventsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.eventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableOrderingComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$UserOverlaysTableAnnotationComposer
    extends Composer<_$AppDatabase, $UserOverlaysTable> {
  $$UserOverlaysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get displayTitle => $composableBuilder(
    column: $table.displayTitle,
    builder: (column) => column,
  );

  GeneratedColumn<String> get attendancePolicy => $composableBuilder(
    column: $table.attendancePolicy,
    builder: (column) => column,
  );

  GeneratedColumn<String> get attendanceDecision => $composableBuilder(
    column: $table.attendanceDecision,
    builder: (column) => column,
  );

  GeneratedColumn<int> get attendanceDecisionAt => $composableBuilder(
    column: $table.attendanceDecisionAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get attendanceNote => $composableBuilder(
    column: $table.attendanceNote,
    builder: (column) => column,
  );

  GeneratedColumn<String> get attendanceOutcome => $composableBuilder(
    column: $table.attendanceOutcome,
    builder: (column) => column,
  );

  GeneratedColumn<String> get listeningMode => $composableBuilder(
    column: $table.listeningMode,
    builder: (column) => column,
  );

  GeneratedColumn<String> get listeningNote => $composableBuilder(
    column: $table.listeningNote,
    builder: (column) => column,
  );

  GeneratedColumn<String> get importance => $composableBuilder(
    column: $table.importance,
    builder: (column) => column,
  );

  GeneratedColumn<String> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<bool> get hidden =>
      $composableBuilder(column: $table.hidden, builder: (column) => column);

  GeneratedColumn<String> get userNotes =>
      $composableBuilder(column: $table.userNotes, builder: (column) => column);

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

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

  $$CalendarEventsTableAnnotationComposer get eventId {
    final $$CalendarEventsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.eventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableAnnotationComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$UserOverlaysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $UserOverlaysTable,
          UserOverlay,
          $$UserOverlaysTableFilterComposer,
          $$UserOverlaysTableOrderingComposer,
          $$UserOverlaysTableAnnotationComposer,
          $$UserOverlaysTableCreateCompanionBuilder,
          $$UserOverlaysTableUpdateCompanionBuilder,
          (UserOverlay, $$UserOverlaysTableReferences),
          UserOverlay,
          PrefetchHooks Function({bool accountId, bool eventId})
        > {
  $$UserOverlaysTableTableManager(_$AppDatabase db, $UserOverlaysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UserOverlaysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UserOverlaysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UserOverlaysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> eventId = const Value.absent(),
                Value<String?> displayTitle = const Value.absent(),
                Value<String?> attendancePolicy = const Value.absent(),
                Value<String?> attendanceDecision = const Value.absent(),
                Value<int?> attendanceDecisionAt = const Value.absent(),
                Value<String?> attendanceNote = const Value.absent(),
                Value<String?> attendanceOutcome = const Value.absent(),
                Value<String?> listeningMode = const Value.absent(),
                Value<String?> listeningNote = const Value.absent(),
                Value<String?> importance = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<bool?> hidden = const Value.absent(),
                Value<String?> userNotes = const Value.absent(),
                Value<String?> tagsJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => UserOverlaysCompanion(
                id: id,
                accountId: accountId,
                eventId: eventId,
                displayTitle: displayTitle,
                attendancePolicy: attendancePolicy,
                attendanceDecision: attendanceDecision,
                attendanceDecisionAt: attendanceDecisionAt,
                attendanceNote: attendanceNote,
                attendanceOutcome: attendanceOutcome,
                listeningMode: listeningMode,
                listeningNote: listeningNote,
                importance: importance,
                color: color,
                hidden: hidden,
                userNotes: userNotes,
                tagsJson: tagsJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String eventId,
                Value<String?> displayTitle = const Value.absent(),
                Value<String?> attendancePolicy = const Value.absent(),
                Value<String?> attendanceDecision = const Value.absent(),
                Value<int?> attendanceDecisionAt = const Value.absent(),
                Value<String?> attendanceNote = const Value.absent(),
                Value<String?> attendanceOutcome = const Value.absent(),
                Value<String?> listeningMode = const Value.absent(),
                Value<String?> listeningNote = const Value.absent(),
                Value<String?> importance = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<bool?> hidden = const Value.absent(),
                Value<String?> userNotes = const Value.absent(),
                Value<String?> tagsJson = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => UserOverlaysCompanion.insert(
                id: id,
                accountId: accountId,
                eventId: eventId,
                displayTitle: displayTitle,
                attendancePolicy: attendancePolicy,
                attendanceDecision: attendanceDecision,
                attendanceDecisionAt: attendanceDecisionAt,
                attendanceNote: attendanceNote,
                attendanceOutcome: attendanceOutcome,
                listeningMode: listeningMode,
                listeningNote: listeningNote,
                importance: importance,
                color: color,
                hidden: hidden,
                userNotes: userNotes,
                tagsJson: tagsJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$UserOverlaysTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false, eventId = false}) {
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
                                referencedTable: $$UserOverlaysTableReferences
                                    ._accountIdTable(db),
                                referencedColumn: $$UserOverlaysTableReferences
                                    ._accountIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (eventId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.eventId,
                                referencedTable: $$UserOverlaysTableReferences
                                    ._eventIdTable(db),
                                referencedColumn: $$UserOverlaysTableReferences
                                    ._eventIdTable(db)
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

typedef $$UserOverlaysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $UserOverlaysTable,
      UserOverlay,
      $$UserOverlaysTableFilterComposer,
      $$UserOverlaysTableOrderingComposer,
      $$UserOverlaysTableAnnotationComposer,
      $$UserOverlaysTableCreateCompanionBuilder,
      $$UserOverlaysTableUpdateCompanionBuilder,
      (UserOverlay, $$UserOverlaysTableReferences),
      UserOverlay,
      PrefetchHooks Function({bool accountId, bool eventId})
    >;
typedef $$TasksTableCreateCompanionBuilder =
    TasksCompanion Function({
      required String id,
      required String accountId,
      required String title,
      Value<String?> description,
      Value<String?> userNotes,
      required String state,
      Value<String?> blockedReason,
      required String importance,
      Value<int?> deadlineAt,
      required String tagsJson,
      Value<int?> terminalAt,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<int> rowid,
    });
typedef $$TasksTableUpdateCompanionBuilder =
    TasksCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> title,
      Value<String?> description,
      Value<String?> userNotes,
      Value<String> state,
      Value<String?> blockedReason,
      Value<String> importance,
      Value<int?> deadlineAt,
      Value<String> tagsJson,
      Value<int?> terminalAt,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<int> rowid,
    });

final class $$TasksTableReferences
    extends BaseReferences<_$AppDatabase, $TasksTable, Task> {
  $$TasksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) =>
      db.localAccounts.createAlias('tasks__account_id__local_accounts__id');

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

  static MultiTypedResultKey<$PlanBlocksTable, List<PlanBlock>>
  _planBlocksRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.planBlocks,
    aliasName: 'tasks__id__plan_blocks__task_id',
  );

  $$PlanBlocksTableProcessedTableManager get planBlocksRefs {
    final manager = $$PlanBlocksTableTableManager(
      $_db,
      $_db.planBlocks,
    ).filter((f) => f.taskId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_planBlocksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$TaskEventLinksTable, List<TaskEventLink>>
  _taskEventLinksRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.taskEventLinks,
    aliasName: 'tasks__id__task_event_links__task_id',
  );

  $$TaskEventLinksTableProcessedTableManager get taskEventLinksRefs {
    final manager = $$TaskEventLinksTableTableManager(
      $_db,
      $_db.taskEventLinks,
    ).filter((f) => f.taskId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_taskEventLinksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$RemindersTable, List<Reminder>>
  _remindersRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.reminders,
    aliasName: 'tasks__id__reminders__task_id',
  );

  $$RemindersTableProcessedTableManager get remindersRefs {
    final manager = $$RemindersTableTableManager(
      $_db,
      $_db.reminders,
    ).filter((f) => f.taskId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_remindersRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$TasksTableFilterComposer extends Composer<_$AppDatabase, $TasksTable> {
  $$TasksTableFilterComposer({
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

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userNotes => $composableBuilder(
    column: $table.userNotes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get blockedReason => $composableBuilder(
    column: $table.blockedReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get importance => $composableBuilder(
    column: $table.importance,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deadlineAt => $composableBuilder(
    column: $table.deadlineAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get terminalAt => $composableBuilder(
    column: $table.terminalAt,
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

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
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

  Expression<bool> planBlocksRefs(
    Expression<bool> Function($$PlanBlocksTableFilterComposer f) f,
  ) {
    final $$PlanBlocksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableFilterComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> taskEventLinksRefs(
    Expression<bool> Function($$TaskEventLinksTableFilterComposer f) f,
  ) {
    final $$TaskEventLinksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskEventLinks,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskEventLinksTableFilterComposer(
            $db: $db,
            $table: $db.taskEventLinks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> remindersRefs(
    Expression<bool> Function($$RemindersTableFilterComposer f) f,
  ) {
    final $$RemindersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.reminders,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RemindersTableFilterComposer(
            $db: $db,
            $table: $db.reminders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TasksTableOrderingComposer
    extends Composer<_$AppDatabase, $TasksTable> {
  $$TasksTableOrderingComposer({
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

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userNotes => $composableBuilder(
    column: $table.userNotes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get blockedReason => $composableBuilder(
    column: $table.blockedReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get importance => $composableBuilder(
    column: $table.importance,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deadlineAt => $composableBuilder(
    column: $table.deadlineAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get terminalAt => $composableBuilder(
    column: $table.terminalAt,
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

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
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

class $$TasksTableAnnotationComposer
    extends Composer<_$AppDatabase, $TasksTable> {
  $$TasksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<String> get userNotes =>
      $composableBuilder(column: $table.userNotes, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get blockedReason => $composableBuilder(
    column: $table.blockedReason,
    builder: (column) => column,
  );

  GeneratedColumn<String> get importance => $composableBuilder(
    column: $table.importance,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deadlineAt => $composableBuilder(
    column: $table.deadlineAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);

  GeneratedColumn<int> get terminalAt => $composableBuilder(
    column: $table.terminalAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

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

  Expression<T> planBlocksRefs<T extends Object>(
    Expression<T> Function($$PlanBlocksTableAnnotationComposer a) f,
  ) {
    final $$PlanBlocksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableAnnotationComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> taskEventLinksRefs<T extends Object>(
    Expression<T> Function($$TaskEventLinksTableAnnotationComposer a) f,
  ) {
    final $$TaskEventLinksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskEventLinks,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskEventLinksTableAnnotationComposer(
            $db: $db,
            $table: $db.taskEventLinks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> remindersRefs<T extends Object>(
    Expression<T> Function($$RemindersTableAnnotationComposer a) f,
  ) {
    final $$RemindersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.reminders,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RemindersTableAnnotationComposer(
            $db: $db,
            $table: $db.reminders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TasksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TasksTable,
          Task,
          $$TasksTableFilterComposer,
          $$TasksTableOrderingComposer,
          $$TasksTableAnnotationComposer,
          $$TasksTableCreateCompanionBuilder,
          $$TasksTableUpdateCompanionBuilder,
          (Task, $$TasksTableReferences),
          Task,
          PrefetchHooks Function({
            bool accountId,
            bool planBlocksRefs,
            bool taskEventLinksRefs,
            bool remindersRefs,
          })
        > {
  $$TasksTableTableManager(_$AppDatabase db, $TasksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TasksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TasksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TasksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<String?> userNotes = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> blockedReason = const Value.absent(),
                Value<String> importance = const Value.absent(),
                Value<int?> deadlineAt = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<int?> terminalAt = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TasksCompanion(
                id: id,
                accountId: accountId,
                title: title,
                description: description,
                userNotes: userNotes,
                state: state,
                blockedReason: blockedReason,
                importance: importance,
                deadlineAt: deadlineAt,
                tagsJson: tagsJson,
                terminalAt: terminalAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String title,
                Value<String?> description = const Value.absent(),
                Value<String?> userNotes = const Value.absent(),
                required String state,
                Value<String?> blockedReason = const Value.absent(),
                required String importance,
                Value<int?> deadlineAt = const Value.absent(),
                required String tagsJson,
                Value<int?> terminalAt = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TasksCompanion.insert(
                id: id,
                accountId: accountId,
                title: title,
                description: description,
                userNotes: userNotes,
                state: state,
                blockedReason: blockedReason,
                importance: importance,
                deadlineAt: deadlineAt,
                tagsJson: tagsJson,
                terminalAt: terminalAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$TasksTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                accountId = false,
                planBlocksRefs = false,
                taskEventLinksRefs = false,
                remindersRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (planBlocksRefs) db.planBlocks,
                    if (taskEventLinksRefs) db.taskEventLinks,
                    if (remindersRefs) db.reminders,
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
                                    referencedTable: $$TasksTableReferences
                                        ._accountIdTable(db),
                                    referencedColumn: $$TasksTableReferences
                                        ._accountIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (planBlocksRefs)
                        await $_getPrefetchedData<Task, $TasksTable, PlanBlock>(
                          currentTable: table,
                          referencedTable: $$TasksTableReferences
                              ._planBlocksRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$TasksTableReferences(
                                db,
                                table,
                                p0,
                              ).planBlocksRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.taskId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (taskEventLinksRefs)
                        await $_getPrefetchedData<
                          Task,
                          $TasksTable,
                          TaskEventLink
                        >(
                          currentTable: table,
                          referencedTable: $$TasksTableReferences
                              ._taskEventLinksRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$TasksTableReferences(
                                db,
                                table,
                                p0,
                              ).taskEventLinksRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.taskId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (remindersRefs)
                        await $_getPrefetchedData<Task, $TasksTable, Reminder>(
                          currentTable: table,
                          referencedTable: $$TasksTableReferences
                              ._remindersRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$TasksTableReferences(
                                db,
                                table,
                                p0,
                              ).remindersRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.taskId == item.id,
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

typedef $$TasksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TasksTable,
      Task,
      $$TasksTableFilterComposer,
      $$TasksTableOrderingComposer,
      $$TasksTableAnnotationComposer,
      $$TasksTableCreateCompanionBuilder,
      $$TasksTableUpdateCompanionBuilder,
      (Task, $$TasksTableReferences),
      Task,
      PrefetchHooks Function({
        bool accountId,
        bool planBlocksRefs,
        bool taskEventLinksRefs,
        bool remindersRefs,
      })
    >;
typedef $$PlanBlocksTableCreateCompanionBuilder =
    PlanBlocksCompanion Function({
      required String id,
      required String accountId,
      required String taskId,
      required int startAt,
      required int endAt,
      required String reviewState,
      Value<String?> reviewNote,
      Value<int?> reviewedAt,
      Value<String?> replacementPlanBlockId,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<int> rowid,
    });
typedef $$PlanBlocksTableUpdateCompanionBuilder =
    PlanBlocksCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> taskId,
      Value<int> startAt,
      Value<int> endAt,
      Value<String> reviewState,
      Value<String?> reviewNote,
      Value<int?> reviewedAt,
      Value<String?> replacementPlanBlockId,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<int> rowid,
    });

final class $$PlanBlocksTableReferences
    extends BaseReferences<_$AppDatabase, $PlanBlocksTable, PlanBlock> {
  $$PlanBlocksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('plan_blocks__account_id__local_accounts__id');

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

  static $TasksTable _taskIdTable(_$AppDatabase db) =>
      db.tasks.createAlias('plan_blocks__task_id__tasks__id');

  $$TasksTableProcessedTableManager get taskId {
    final $_column = $_itemColumn<String>('task_id')!;

    final manager = $$TasksTableTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_taskIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$ScheduleRelationsTable, List<ScheduleRelation>>
  _leftPlanBlockRelationsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.scheduleRelations,
        aliasName: 'plan_blocks__id__schedule_relations__left_plan_block_id',
      );

  $$ScheduleRelationsTableProcessedTableManager get leftPlanBlockRelations {
    final manager =
        $$ScheduleRelationsTableTableManager(
          $_db,
          $_db.scheduleRelations,
        ).filter(
          (f) => f.leftPlanBlockId.id.sqlEquals($_itemColumn<String>('id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _leftPlanBlockRelationsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ScheduleRelationsTable, List<ScheduleRelation>>
  _rightPlanBlockRelationsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.scheduleRelations,
        aliasName: 'plan_blocks__id__schedule_relations__right_plan_block_id',
      );

  $$ScheduleRelationsTableProcessedTableManager get rightPlanBlockRelations {
    final manager =
        $$ScheduleRelationsTableTableManager(
          $_db,
          $_db.scheduleRelations,
        ).filter(
          (f) => f.rightPlanBlockId.id.sqlEquals($_itemColumn<String>('id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _rightPlanBlockRelationsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$RemindersTable, List<Reminder>>
  _remindersRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.reminders,
    aliasName: 'plan_blocks__id__reminders__plan_block_id',
  );

  $$RemindersTableProcessedTableManager get remindersRefs {
    final manager = $$RemindersTableTableManager(
      $_db,
      $_db.reminders,
    ).filter((f) => f.planBlockId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_remindersRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$PlanBlocksTableFilterComposer
    extends Composer<_$AppDatabase, $PlanBlocksTable> {
  $$PlanBlocksTableFilterComposer({
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

  ColumnFilters<int> get startAt => $composableBuilder(
    column: $table.startAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endAt => $composableBuilder(
    column: $table.endAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reviewState => $composableBuilder(
    column: $table.reviewState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reviewNote => $composableBuilder(
    column: $table.reviewNote,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reviewedAt => $composableBuilder(
    column: $table.reviewedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replacementPlanBlockId => $composableBuilder(
    column: $table.replacementPlanBlockId,
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

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
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

  $$TasksTableFilterComposer get taskId {
    final $$TasksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> leftPlanBlockRelations(
    Expression<bool> Function($$ScheduleRelationsTableFilterComposer f) f,
  ) {
    final $$ScheduleRelationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scheduleRelations,
      getReferencedColumn: (t) => t.leftPlanBlockId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScheduleRelationsTableFilterComposer(
            $db: $db,
            $table: $db.scheduleRelations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> rightPlanBlockRelations(
    Expression<bool> Function($$ScheduleRelationsTableFilterComposer f) f,
  ) {
    final $$ScheduleRelationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scheduleRelations,
      getReferencedColumn: (t) => t.rightPlanBlockId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScheduleRelationsTableFilterComposer(
            $db: $db,
            $table: $db.scheduleRelations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> remindersRefs(
    Expression<bool> Function($$RemindersTableFilterComposer f) f,
  ) {
    final $$RemindersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.reminders,
      getReferencedColumn: (t) => t.planBlockId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RemindersTableFilterComposer(
            $db: $db,
            $table: $db.reminders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlanBlocksTableOrderingComposer
    extends Composer<_$AppDatabase, $PlanBlocksTable> {
  $$PlanBlocksTableOrderingComposer({
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

  ColumnOrderings<int> get startAt => $composableBuilder(
    column: $table.startAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endAt => $composableBuilder(
    column: $table.endAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reviewState => $composableBuilder(
    column: $table.reviewState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reviewNote => $composableBuilder(
    column: $table.reviewNote,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reviewedAt => $composableBuilder(
    column: $table.reviewedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replacementPlanBlockId => $composableBuilder(
    column: $table.replacementPlanBlockId,
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

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
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

  $$TasksTableOrderingComposer get taskId {
    final $$TasksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableOrderingComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlanBlocksTableAnnotationComposer
    extends Composer<_$AppDatabase, $PlanBlocksTable> {
  $$PlanBlocksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get startAt =>
      $composableBuilder(column: $table.startAt, builder: (column) => column);

  GeneratedColumn<int> get endAt =>
      $composableBuilder(column: $table.endAt, builder: (column) => column);

  GeneratedColumn<String> get reviewState => $composableBuilder(
    column: $table.reviewState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reviewNote => $composableBuilder(
    column: $table.reviewNote,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reviewedAt => $composableBuilder(
    column: $table.reviewedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get replacementPlanBlockId => $composableBuilder(
    column: $table.replacementPlanBlockId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

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

  $$TasksTableAnnotationComposer get taskId {
    final $$TasksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> leftPlanBlockRelations<T extends Object>(
    Expression<T> Function($$ScheduleRelationsTableAnnotationComposer a) f,
  ) {
    final $$ScheduleRelationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.scheduleRelations,
          getReferencedColumn: (t) => t.leftPlanBlockId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ScheduleRelationsTableAnnotationComposer(
                $db: $db,
                $table: $db.scheduleRelations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> rightPlanBlockRelations<T extends Object>(
    Expression<T> Function($$ScheduleRelationsTableAnnotationComposer a) f,
  ) {
    final $$ScheduleRelationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.scheduleRelations,
          getReferencedColumn: (t) => t.rightPlanBlockId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ScheduleRelationsTableAnnotationComposer(
                $db: $db,
                $table: $db.scheduleRelations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> remindersRefs<T extends Object>(
    Expression<T> Function($$RemindersTableAnnotationComposer a) f,
  ) {
    final $$RemindersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.reminders,
      getReferencedColumn: (t) => t.planBlockId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RemindersTableAnnotationComposer(
            $db: $db,
            $table: $db.reminders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlanBlocksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PlanBlocksTable,
          PlanBlock,
          $$PlanBlocksTableFilterComposer,
          $$PlanBlocksTableOrderingComposer,
          $$PlanBlocksTableAnnotationComposer,
          $$PlanBlocksTableCreateCompanionBuilder,
          $$PlanBlocksTableUpdateCompanionBuilder,
          (PlanBlock, $$PlanBlocksTableReferences),
          PlanBlock,
          PrefetchHooks Function({
            bool accountId,
            bool taskId,
            bool leftPlanBlockRelations,
            bool rightPlanBlockRelations,
            bool remindersRefs,
          })
        > {
  $$PlanBlocksTableTableManager(_$AppDatabase db, $PlanBlocksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlanBlocksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlanBlocksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlanBlocksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> taskId = const Value.absent(),
                Value<int> startAt = const Value.absent(),
                Value<int> endAt = const Value.absent(),
                Value<String> reviewState = const Value.absent(),
                Value<String?> reviewNote = const Value.absent(),
                Value<int?> reviewedAt = const Value.absent(),
                Value<String?> replacementPlanBlockId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlanBlocksCompanion(
                id: id,
                accountId: accountId,
                taskId: taskId,
                startAt: startAt,
                endAt: endAt,
                reviewState: reviewState,
                reviewNote: reviewNote,
                reviewedAt: reviewedAt,
                replacementPlanBlockId: replacementPlanBlockId,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String taskId,
                required int startAt,
                required int endAt,
                required String reviewState,
                Value<String?> reviewNote = const Value.absent(),
                Value<int?> reviewedAt = const Value.absent(),
                Value<String?> replacementPlanBlockId = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlanBlocksCompanion.insert(
                id: id,
                accountId: accountId,
                taskId: taskId,
                startAt: startAt,
                endAt: endAt,
                reviewState: reviewState,
                reviewNote: reviewNote,
                reviewedAt: reviewedAt,
                replacementPlanBlockId: replacementPlanBlockId,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PlanBlocksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                accountId = false,
                taskId = false,
                leftPlanBlockRelations = false,
                rightPlanBlockRelations = false,
                remindersRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (leftPlanBlockRelations) db.scheduleRelations,
                    if (rightPlanBlockRelations) db.scheduleRelations,
                    if (remindersRefs) db.reminders,
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
                                    referencedTable: $$PlanBlocksTableReferences
                                        ._accountIdTable(db),
                                    referencedColumn:
                                        $$PlanBlocksTableReferences
                                            ._accountIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (taskId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.taskId,
                                    referencedTable: $$PlanBlocksTableReferences
                                        ._taskIdTable(db),
                                    referencedColumn:
                                        $$PlanBlocksTableReferences
                                            ._taskIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (leftPlanBlockRelations)
                        await $_getPrefetchedData<
                          PlanBlock,
                          $PlanBlocksTable,
                          ScheduleRelation
                        >(
                          currentTable: table,
                          referencedTable: $$PlanBlocksTableReferences
                              ._leftPlanBlockRelationsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PlanBlocksTableReferences(
                                db,
                                table,
                                p0,
                              ).leftPlanBlockRelations,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.leftPlanBlockId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (rightPlanBlockRelations)
                        await $_getPrefetchedData<
                          PlanBlock,
                          $PlanBlocksTable,
                          ScheduleRelation
                        >(
                          currentTable: table,
                          referencedTable: $$PlanBlocksTableReferences
                              ._rightPlanBlockRelationsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PlanBlocksTableReferences(
                                db,
                                table,
                                p0,
                              ).rightPlanBlockRelations,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.rightPlanBlockId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (remindersRefs)
                        await $_getPrefetchedData<
                          PlanBlock,
                          $PlanBlocksTable,
                          Reminder
                        >(
                          currentTable: table,
                          referencedTable: $$PlanBlocksTableReferences
                              ._remindersRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PlanBlocksTableReferences(
                                db,
                                table,
                                p0,
                              ).remindersRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.planBlockId == item.id,
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

typedef $$PlanBlocksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PlanBlocksTable,
      PlanBlock,
      $$PlanBlocksTableFilterComposer,
      $$PlanBlocksTableOrderingComposer,
      $$PlanBlocksTableAnnotationComposer,
      $$PlanBlocksTableCreateCompanionBuilder,
      $$PlanBlocksTableUpdateCompanionBuilder,
      (PlanBlock, $$PlanBlocksTableReferences),
      PlanBlock,
      PrefetchHooks Function({
        bool accountId,
        bool taskId,
        bool leftPlanBlockRelations,
        bool rightPlanBlockRelations,
        bool remindersRefs,
      })
    >;
typedef $$TaskEventLinksTableCreateCompanionBuilder =
    TaskEventLinksCompanion Function({
      required String accountId,
      required String taskId,
      required String eventId,
      required String relationType,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$TaskEventLinksTableUpdateCompanionBuilder =
    TaskEventLinksCompanion Function({
      Value<String> accountId,
      Value<String> taskId,
      Value<String> eventId,
      Value<String> relationType,
      Value<int> createdAt,
      Value<int> rowid,
    });

final class $$TaskEventLinksTableReferences
    extends BaseReferences<_$AppDatabase, $TaskEventLinksTable, TaskEventLink> {
  $$TaskEventLinksTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('task_event_links__account_id__local_accounts__id');

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

  static $TasksTable _taskIdTable(_$AppDatabase db) =>
      db.tasks.createAlias('task_event_links__task_id__tasks__id');

  $$TasksTableProcessedTableManager get taskId {
    final $_column = $_itemColumn<String>('task_id')!;

    final manager = $$TasksTableTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_taskIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $CalendarEventsTable _eventIdTable(_$AppDatabase db) => db
      .calendarEvents
      .createAlias('task_event_links__event_id__calendar_events__id');

  $$CalendarEventsTableProcessedTableManager get eventId {
    final $_column = $_itemColumn<String>('event_id')!;

    final manager = $$CalendarEventsTableTableManager(
      $_db,
      $_db.calendarEvents,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_eventIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$TaskEventLinksTableFilterComposer
    extends Composer<_$AppDatabase, $TaskEventLinksTable> {
  $$TaskEventLinksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get relationType => $composableBuilder(
    column: $table.relationType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
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

  $$TasksTableFilterComposer get taskId {
    final $$TasksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CalendarEventsTableFilterComposer get eventId {
    final $$CalendarEventsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.eventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableFilterComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TaskEventLinksTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskEventLinksTable> {
  $$TaskEventLinksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get relationType => $composableBuilder(
    column: $table.relationType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
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

  $$TasksTableOrderingComposer get taskId {
    final $$TasksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableOrderingComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CalendarEventsTableOrderingComposer get eventId {
    final $$CalendarEventsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.eventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableOrderingComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TaskEventLinksTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskEventLinksTable> {
  $$TaskEventLinksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get relationType => $composableBuilder(
    column: $table.relationType,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

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

  $$TasksTableAnnotationComposer get taskId {
    final $$TasksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CalendarEventsTableAnnotationComposer get eventId {
    final $$CalendarEventsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.eventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableAnnotationComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TaskEventLinksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskEventLinksTable,
          TaskEventLink,
          $$TaskEventLinksTableFilterComposer,
          $$TaskEventLinksTableOrderingComposer,
          $$TaskEventLinksTableAnnotationComposer,
          $$TaskEventLinksTableCreateCompanionBuilder,
          $$TaskEventLinksTableUpdateCompanionBuilder,
          (TaskEventLink, $$TaskEventLinksTableReferences),
          TaskEventLink,
          PrefetchHooks Function({bool accountId, bool taskId, bool eventId})
        > {
  $$TaskEventLinksTableTableManager(
    _$AppDatabase db,
    $TaskEventLinksTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskEventLinksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TaskEventLinksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TaskEventLinksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> taskId = const Value.absent(),
                Value<String> eventId = const Value.absent(),
                Value<String> relationType = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskEventLinksCompanion(
                accountId: accountId,
                taskId: taskId,
                eventId: eventId,
                relationType: relationType,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String taskId,
                required String eventId,
                required String relationType,
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => TaskEventLinksCompanion.insert(
                accountId: accountId,
                taskId: taskId,
                eventId: eventId,
                relationType: relationType,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$TaskEventLinksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({accountId = false, taskId = false, eventId = false}) {
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
                                        $$TaskEventLinksTableReferences
                                            ._accountIdTable(db),
                                    referencedColumn:
                                        $$TaskEventLinksTableReferences
                                            ._accountIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (taskId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.taskId,
                                    referencedTable:
                                        $$TaskEventLinksTableReferences
                                            ._taskIdTable(db),
                                    referencedColumn:
                                        $$TaskEventLinksTableReferences
                                            ._taskIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (eventId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.eventId,
                                    referencedTable:
                                        $$TaskEventLinksTableReferences
                                            ._eventIdTable(db),
                                    referencedColumn:
                                        $$TaskEventLinksTableReferences
                                            ._eventIdTable(db)
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

typedef $$TaskEventLinksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskEventLinksTable,
      TaskEventLink,
      $$TaskEventLinksTableFilterComposer,
      $$TaskEventLinksTableOrderingComposer,
      $$TaskEventLinksTableAnnotationComposer,
      $$TaskEventLinksTableCreateCompanionBuilder,
      $$TaskEventLinksTableUpdateCompanionBuilder,
      (TaskEventLink, $$TaskEventLinksTableReferences),
      TaskEventLink,
      PrefetchHooks Function({bool accountId, bool taskId, bool eventId})
    >;
typedef $$ScheduleRelationsTableCreateCompanionBuilder =
    ScheduleRelationsCompanion Function({
      required String id,
      required String accountId,
      Value<String> source,
      Value<String?> externalId,
      Value<String> relationType,
      Value<String?> primaryEntityType,
      Value<String?> primaryEntityId,
      Value<String?> relatedEntityType,
      Value<String?> relatedEntityId,
      Value<String?> leftKind,
      Value<String?> leftId,
      Value<String?> rightKind,
      Value<String?> rightId,
      Value<String?> leftEventId,
      Value<String?> leftPlanBlockId,
      Value<String?> rightEventId,
      Value<String?> rightPlanBlockId,
      Value<String?> conflictState,
      Value<String?> reason,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$ScheduleRelationsTableUpdateCompanionBuilder =
    ScheduleRelationsCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> source,
      Value<String?> externalId,
      Value<String> relationType,
      Value<String?> primaryEntityType,
      Value<String?> primaryEntityId,
      Value<String?> relatedEntityType,
      Value<String?> relatedEntityId,
      Value<String?> leftKind,
      Value<String?> leftId,
      Value<String?> rightKind,
      Value<String?> rightId,
      Value<String?> leftEventId,
      Value<String?> leftPlanBlockId,
      Value<String?> rightEventId,
      Value<String?> rightPlanBlockId,
      Value<String?> conflictState,
      Value<String?> reason,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$ScheduleRelationsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $ScheduleRelationsTable,
          ScheduleRelation
        > {
  $$ScheduleRelationsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('schedule_relations__account_id__local_accounts__id');

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

  static $CalendarEventsTable _leftEventIdTable(_$AppDatabase db) => db
      .calendarEvents
      .createAlias('schedule_relations__left_event_id__calendar_events__id');

  $$CalendarEventsTableProcessedTableManager? get leftEventId {
    final $_column = $_itemColumn<String>('left_event_id');
    if ($_column == null) return null;
    final manager = $$CalendarEventsTableTableManager(
      $_db,
      $_db.calendarEvents,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_leftEventIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $PlanBlocksTable _leftPlanBlockIdTable(_$AppDatabase db) => db
      .planBlocks
      .createAlias('schedule_relations__left_plan_block_id__plan_blocks__id');

  $$PlanBlocksTableProcessedTableManager? get leftPlanBlockId {
    final $_column = $_itemColumn<String>('left_plan_block_id');
    if ($_column == null) return null;
    final manager = $$PlanBlocksTableTableManager(
      $_db,
      $_db.planBlocks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_leftPlanBlockIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $CalendarEventsTable _rightEventIdTable(_$AppDatabase db) => db
      .calendarEvents
      .createAlias('schedule_relations__right_event_id__calendar_events__id');

  $$CalendarEventsTableProcessedTableManager? get rightEventId {
    final $_column = $_itemColumn<String>('right_event_id');
    if ($_column == null) return null;
    final manager = $$CalendarEventsTableTableManager(
      $_db,
      $_db.calendarEvents,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_rightEventIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $PlanBlocksTable _rightPlanBlockIdTable(_$AppDatabase db) => db
      .planBlocks
      .createAlias('schedule_relations__right_plan_block_id__plan_blocks__id');

  $$PlanBlocksTableProcessedTableManager? get rightPlanBlockId {
    final $_column = $_itemColumn<String>('right_plan_block_id');
    if ($_column == null) return null;
    final manager = $$PlanBlocksTableTableManager(
      $_db,
      $_db.planBlocks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_rightPlanBlockIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ScheduleRelationsTableFilterComposer
    extends Composer<_$AppDatabase, $ScheduleRelationsTable> {
  $$ScheduleRelationsTableFilterComposer({
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

  ColumnFilters<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relationType => $composableBuilder(
    column: $table.relationType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get primaryEntityType => $composableBuilder(
    column: $table.primaryEntityType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get primaryEntityId => $composableBuilder(
    column: $table.primaryEntityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relatedEntityType => $composableBuilder(
    column: $table.relatedEntityType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relatedEntityId => $composableBuilder(
    column: $table.relatedEntityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get leftKind => $composableBuilder(
    column: $table.leftKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get leftId => $composableBuilder(
    column: $table.leftId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rightKind => $composableBuilder(
    column: $table.rightKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rightId => $composableBuilder(
    column: $table.rightId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conflictState => $composableBuilder(
    column: $table.conflictState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reason => $composableBuilder(
    column: $table.reason,
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

  $$CalendarEventsTableFilterComposer get leftEventId {
    final $$CalendarEventsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.leftEventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableFilterComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlanBlocksTableFilterComposer get leftPlanBlockId {
    final $$PlanBlocksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.leftPlanBlockId,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableFilterComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CalendarEventsTableFilterComposer get rightEventId {
    final $$CalendarEventsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rightEventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableFilterComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlanBlocksTableFilterComposer get rightPlanBlockId {
    final $$PlanBlocksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rightPlanBlockId,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableFilterComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScheduleRelationsTableOrderingComposer
    extends Composer<_$AppDatabase, $ScheduleRelationsTable> {
  $$ScheduleRelationsTableOrderingComposer({
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

  ColumnOrderings<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relationType => $composableBuilder(
    column: $table.relationType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get primaryEntityType => $composableBuilder(
    column: $table.primaryEntityType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get primaryEntityId => $composableBuilder(
    column: $table.primaryEntityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relatedEntityType => $composableBuilder(
    column: $table.relatedEntityType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relatedEntityId => $composableBuilder(
    column: $table.relatedEntityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get leftKind => $composableBuilder(
    column: $table.leftKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get leftId => $composableBuilder(
    column: $table.leftId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rightKind => $composableBuilder(
    column: $table.rightKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rightId => $composableBuilder(
    column: $table.rightId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conflictState => $composableBuilder(
    column: $table.conflictState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reason => $composableBuilder(
    column: $table.reason,
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

  $$CalendarEventsTableOrderingComposer get leftEventId {
    final $$CalendarEventsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.leftEventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableOrderingComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlanBlocksTableOrderingComposer get leftPlanBlockId {
    final $$PlanBlocksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.leftPlanBlockId,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableOrderingComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CalendarEventsTableOrderingComposer get rightEventId {
    final $$CalendarEventsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rightEventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableOrderingComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlanBlocksTableOrderingComposer get rightPlanBlockId {
    final $$PlanBlocksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rightPlanBlockId,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableOrderingComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScheduleRelationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ScheduleRelationsTable> {
  $$ScheduleRelationsTableAnnotationComposer({
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

  GeneratedColumn<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get relationType => $composableBuilder(
    column: $table.relationType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get primaryEntityType => $composableBuilder(
    column: $table.primaryEntityType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get primaryEntityId => $composableBuilder(
    column: $table.primaryEntityId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get relatedEntityType => $composableBuilder(
    column: $table.relatedEntityType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get relatedEntityId => $composableBuilder(
    column: $table.relatedEntityId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get leftKind =>
      $composableBuilder(column: $table.leftKind, builder: (column) => column);

  GeneratedColumn<String> get leftId =>
      $composableBuilder(column: $table.leftId, builder: (column) => column);

  GeneratedColumn<String> get rightKind =>
      $composableBuilder(column: $table.rightKind, builder: (column) => column);

  GeneratedColumn<String> get rightId =>
      $composableBuilder(column: $table.rightId, builder: (column) => column);

  GeneratedColumn<String> get conflictState => $composableBuilder(
    column: $table.conflictState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reason =>
      $composableBuilder(column: $table.reason, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

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

  $$CalendarEventsTableAnnotationComposer get leftEventId {
    final $$CalendarEventsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.leftEventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableAnnotationComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlanBlocksTableAnnotationComposer get leftPlanBlockId {
    final $$PlanBlocksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.leftPlanBlockId,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableAnnotationComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CalendarEventsTableAnnotationComposer get rightEventId {
    final $$CalendarEventsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rightEventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableAnnotationComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlanBlocksTableAnnotationComposer get rightPlanBlockId {
    final $$PlanBlocksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rightPlanBlockId,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableAnnotationComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScheduleRelationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ScheduleRelationsTable,
          ScheduleRelation,
          $$ScheduleRelationsTableFilterComposer,
          $$ScheduleRelationsTableOrderingComposer,
          $$ScheduleRelationsTableAnnotationComposer,
          $$ScheduleRelationsTableCreateCompanionBuilder,
          $$ScheduleRelationsTableUpdateCompanionBuilder,
          (ScheduleRelation, $$ScheduleRelationsTableReferences),
          ScheduleRelation,
          PrefetchHooks Function({
            bool accountId,
            bool leftEventId,
            bool leftPlanBlockId,
            bool rightEventId,
            bool rightPlanBlockId,
          })
        > {
  $$ScheduleRelationsTableTableManager(
    _$AppDatabase db,
    $ScheduleRelationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ScheduleRelationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ScheduleRelationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ScheduleRelationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> externalId = const Value.absent(),
                Value<String> relationType = const Value.absent(),
                Value<String?> primaryEntityType = const Value.absent(),
                Value<String?> primaryEntityId = const Value.absent(),
                Value<String?> relatedEntityType = const Value.absent(),
                Value<String?> relatedEntityId = const Value.absent(),
                Value<String?> leftKind = const Value.absent(),
                Value<String?> leftId = const Value.absent(),
                Value<String?> rightKind = const Value.absent(),
                Value<String?> rightId = const Value.absent(),
                Value<String?> leftEventId = const Value.absent(),
                Value<String?> leftPlanBlockId = const Value.absent(),
                Value<String?> rightEventId = const Value.absent(),
                Value<String?> rightPlanBlockId = const Value.absent(),
                Value<String?> conflictState = const Value.absent(),
                Value<String?> reason = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScheduleRelationsCompanion(
                id: id,
                accountId: accountId,
                source: source,
                externalId: externalId,
                relationType: relationType,
                primaryEntityType: primaryEntityType,
                primaryEntityId: primaryEntityId,
                relatedEntityType: relatedEntityType,
                relatedEntityId: relatedEntityId,
                leftKind: leftKind,
                leftId: leftId,
                rightKind: rightKind,
                rightId: rightId,
                leftEventId: leftEventId,
                leftPlanBlockId: leftPlanBlockId,
                rightEventId: rightEventId,
                rightPlanBlockId: rightPlanBlockId,
                conflictState: conflictState,
                reason: reason,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                Value<String> source = const Value.absent(),
                Value<String?> externalId = const Value.absent(),
                Value<String> relationType = const Value.absent(),
                Value<String?> primaryEntityType = const Value.absent(),
                Value<String?> primaryEntityId = const Value.absent(),
                Value<String?> relatedEntityType = const Value.absent(),
                Value<String?> relatedEntityId = const Value.absent(),
                Value<String?> leftKind = const Value.absent(),
                Value<String?> leftId = const Value.absent(),
                Value<String?> rightKind = const Value.absent(),
                Value<String?> rightId = const Value.absent(),
                Value<String?> leftEventId = const Value.absent(),
                Value<String?> leftPlanBlockId = const Value.absent(),
                Value<String?> rightEventId = const Value.absent(),
                Value<String?> rightPlanBlockId = const Value.absent(),
                Value<String?> conflictState = const Value.absent(),
                Value<String?> reason = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => ScheduleRelationsCompanion.insert(
                id: id,
                accountId: accountId,
                source: source,
                externalId: externalId,
                relationType: relationType,
                primaryEntityType: primaryEntityType,
                primaryEntityId: primaryEntityId,
                relatedEntityType: relatedEntityType,
                relatedEntityId: relatedEntityId,
                leftKind: leftKind,
                leftId: leftId,
                rightKind: rightKind,
                rightId: rightId,
                leftEventId: leftEventId,
                leftPlanBlockId: leftPlanBlockId,
                rightEventId: rightEventId,
                rightPlanBlockId: rightPlanBlockId,
                conflictState: conflictState,
                reason: reason,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ScheduleRelationsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                accountId = false,
                leftEventId = false,
                leftPlanBlockId = false,
                rightEventId = false,
                rightPlanBlockId = false,
              }) {
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
                                        $$ScheduleRelationsTableReferences
                                            ._accountIdTable(db),
                                    referencedColumn:
                                        $$ScheduleRelationsTableReferences
                                            ._accountIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (leftEventId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.leftEventId,
                                    referencedTable:
                                        $$ScheduleRelationsTableReferences
                                            ._leftEventIdTable(db),
                                    referencedColumn:
                                        $$ScheduleRelationsTableReferences
                                            ._leftEventIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (leftPlanBlockId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.leftPlanBlockId,
                                    referencedTable:
                                        $$ScheduleRelationsTableReferences
                                            ._leftPlanBlockIdTable(db),
                                    referencedColumn:
                                        $$ScheduleRelationsTableReferences
                                            ._leftPlanBlockIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (rightEventId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.rightEventId,
                                    referencedTable:
                                        $$ScheduleRelationsTableReferences
                                            ._rightEventIdTable(db),
                                    referencedColumn:
                                        $$ScheduleRelationsTableReferences
                                            ._rightEventIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (rightPlanBlockId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.rightPlanBlockId,
                                    referencedTable:
                                        $$ScheduleRelationsTableReferences
                                            ._rightPlanBlockIdTable(db),
                                    referencedColumn:
                                        $$ScheduleRelationsTableReferences
                                            ._rightPlanBlockIdTable(db)
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

typedef $$ScheduleRelationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ScheduleRelationsTable,
      ScheduleRelation,
      $$ScheduleRelationsTableFilterComposer,
      $$ScheduleRelationsTableOrderingComposer,
      $$ScheduleRelationsTableAnnotationComposer,
      $$ScheduleRelationsTableCreateCompanionBuilder,
      $$ScheduleRelationsTableUpdateCompanionBuilder,
      (ScheduleRelation, $$ScheduleRelationsTableReferences),
      ScheduleRelation,
      PrefetchHooks Function({
        bool accountId,
        bool leftEventId,
        bool leftPlanBlockId,
        bool rightEventId,
        bool rightPlanBlockId,
      })
    >;
typedef $$ScheduleRelationRulesTableCreateCompanionBuilder =
    ScheduleRelationRulesCompanion Function({
      required String id,
      required String accountId,
      required String leftSeriesType,
      required String leftSeriesId,
      required String rightSeriesType,
      required String rightSeriesId,
      required String conflictState,
      Value<String?> reason,
      required String effectiveFrom,
      Value<String?> effectiveThrough,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$ScheduleRelationRulesTableUpdateCompanionBuilder =
    ScheduleRelationRulesCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> leftSeriesType,
      Value<String> leftSeriesId,
      Value<String> rightSeriesType,
      Value<String> rightSeriesId,
      Value<String> conflictState,
      Value<String?> reason,
      Value<String> effectiveFrom,
      Value<String?> effectiveThrough,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$ScheduleRelationRulesTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $ScheduleRelationRulesTable,
          ScheduleRelationRule
        > {
  $$ScheduleRelationRulesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) => db
      .localAccounts
      .createAlias('schedule_relation_rules__account_id__local_accounts__id');

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

class $$ScheduleRelationRulesTableFilterComposer
    extends Composer<_$AppDatabase, $ScheduleRelationRulesTable> {
  $$ScheduleRelationRulesTableFilterComposer({
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

  ColumnFilters<String> get leftSeriesType => $composableBuilder(
    column: $table.leftSeriesType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get leftSeriesId => $composableBuilder(
    column: $table.leftSeriesId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rightSeriesType => $composableBuilder(
    column: $table.rightSeriesType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rightSeriesId => $composableBuilder(
    column: $table.rightSeriesId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conflictState => $composableBuilder(
    column: $table.conflictState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reason => $composableBuilder(
    column: $table.reason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get effectiveFrom => $composableBuilder(
    column: $table.effectiveFrom,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get effectiveThrough => $composableBuilder(
    column: $table.effectiveThrough,
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

class $$ScheduleRelationRulesTableOrderingComposer
    extends Composer<_$AppDatabase, $ScheduleRelationRulesTable> {
  $$ScheduleRelationRulesTableOrderingComposer({
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

  ColumnOrderings<String> get leftSeriesType => $composableBuilder(
    column: $table.leftSeriesType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get leftSeriesId => $composableBuilder(
    column: $table.leftSeriesId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rightSeriesType => $composableBuilder(
    column: $table.rightSeriesType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rightSeriesId => $composableBuilder(
    column: $table.rightSeriesId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conflictState => $composableBuilder(
    column: $table.conflictState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reason => $composableBuilder(
    column: $table.reason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get effectiveFrom => $composableBuilder(
    column: $table.effectiveFrom,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get effectiveThrough => $composableBuilder(
    column: $table.effectiveThrough,
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

class $$ScheduleRelationRulesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ScheduleRelationRulesTable> {
  $$ScheduleRelationRulesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get leftSeriesType => $composableBuilder(
    column: $table.leftSeriesType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get leftSeriesId => $composableBuilder(
    column: $table.leftSeriesId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get rightSeriesType => $composableBuilder(
    column: $table.rightSeriesType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get rightSeriesId => $composableBuilder(
    column: $table.rightSeriesId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get conflictState => $composableBuilder(
    column: $table.conflictState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reason =>
      $composableBuilder(column: $table.reason, builder: (column) => column);

  GeneratedColumn<String> get effectiveFrom => $composableBuilder(
    column: $table.effectiveFrom,
    builder: (column) => column,
  );

  GeneratedColumn<String> get effectiveThrough => $composableBuilder(
    column: $table.effectiveThrough,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

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

class $$ScheduleRelationRulesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ScheduleRelationRulesTable,
          ScheduleRelationRule,
          $$ScheduleRelationRulesTableFilterComposer,
          $$ScheduleRelationRulesTableOrderingComposer,
          $$ScheduleRelationRulesTableAnnotationComposer,
          $$ScheduleRelationRulesTableCreateCompanionBuilder,
          $$ScheduleRelationRulesTableUpdateCompanionBuilder,
          (ScheduleRelationRule, $$ScheduleRelationRulesTableReferences),
          ScheduleRelationRule,
          PrefetchHooks Function({bool accountId})
        > {
  $$ScheduleRelationRulesTableTableManager(
    _$AppDatabase db,
    $ScheduleRelationRulesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ScheduleRelationRulesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$ScheduleRelationRulesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ScheduleRelationRulesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> leftSeriesType = const Value.absent(),
                Value<String> leftSeriesId = const Value.absent(),
                Value<String> rightSeriesType = const Value.absent(),
                Value<String> rightSeriesId = const Value.absent(),
                Value<String> conflictState = const Value.absent(),
                Value<String?> reason = const Value.absent(),
                Value<String> effectiveFrom = const Value.absent(),
                Value<String?> effectiveThrough = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScheduleRelationRulesCompanion(
                id: id,
                accountId: accountId,
                leftSeriesType: leftSeriesType,
                leftSeriesId: leftSeriesId,
                rightSeriesType: rightSeriesType,
                rightSeriesId: rightSeriesId,
                conflictState: conflictState,
                reason: reason,
                effectiveFrom: effectiveFrom,
                effectiveThrough: effectiveThrough,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String leftSeriesType,
                required String leftSeriesId,
                required String rightSeriesType,
                required String rightSeriesId,
                required String conflictState,
                Value<String?> reason = const Value.absent(),
                required String effectiveFrom,
                Value<String?> effectiveThrough = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => ScheduleRelationRulesCompanion.insert(
                id: id,
                accountId: accountId,
                leftSeriesType: leftSeriesType,
                leftSeriesId: leftSeriesId,
                rightSeriesType: rightSeriesType,
                rightSeriesId: rightSeriesId,
                conflictState: conflictState,
                reason: reason,
                effectiveFrom: effectiveFrom,
                effectiveThrough: effectiveThrough,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ScheduleRelationRulesTableReferences(db, table, e),
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
                                    $$ScheduleRelationRulesTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$ScheduleRelationRulesTableReferences
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

typedef $$ScheduleRelationRulesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ScheduleRelationRulesTable,
      ScheduleRelationRule,
      $$ScheduleRelationRulesTableFilterComposer,
      $$ScheduleRelationRulesTableOrderingComposer,
      $$ScheduleRelationRulesTableAnnotationComposer,
      $$ScheduleRelationRulesTableCreateCompanionBuilder,
      $$ScheduleRelationRulesTableUpdateCompanionBuilder,
      (ScheduleRelationRule, $$ScheduleRelationRulesTableReferences),
      ScheduleRelationRule,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$RemindersTableCreateCompanionBuilder =
    RemindersCompanion Function({
      required String id,
      required String accountId,
      required String targetType,
      required String targetId,
      Value<String?> eventId,
      Value<String?> taskId,
      Value<String?> planBlockId,
      Value<int?> offsetMinutes,
      required int triggerAt,
      required String state,
      Value<String?> failureCode,
      Value<int?> deliveredAt,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$RemindersTableUpdateCompanionBuilder =
    RemindersCompanion Function({
      Value<String> id,
      Value<String> accountId,
      Value<String> targetType,
      Value<String> targetId,
      Value<String?> eventId,
      Value<String?> taskId,
      Value<String?> planBlockId,
      Value<int?> offsetMinutes,
      Value<int> triggerAt,
      Value<String> state,
      Value<String?> failureCode,
      Value<int?> deliveredAt,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$RemindersTableReferences
    extends BaseReferences<_$AppDatabase, $RemindersTable, Reminder> {
  $$RemindersTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalAccountsTable _accountIdTable(_$AppDatabase db) =>
      db.localAccounts.createAlias('reminders__account_id__local_accounts__id');

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

  static $CalendarEventsTable _eventIdTable(_$AppDatabase db) =>
      db.calendarEvents.createAlias('reminders__event_id__calendar_events__id');

  $$CalendarEventsTableProcessedTableManager? get eventId {
    final $_column = $_itemColumn<String>('event_id');
    if ($_column == null) return null;
    final manager = $$CalendarEventsTableTableManager(
      $_db,
      $_db.calendarEvents,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_eventIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $TasksTable _taskIdTable(_$AppDatabase db) =>
      db.tasks.createAlias('reminders__task_id__tasks__id');

  $$TasksTableProcessedTableManager? get taskId {
    final $_column = $_itemColumn<String>('task_id');
    if ($_column == null) return null;
    final manager = $$TasksTableTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_taskIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $PlanBlocksTable _planBlockIdTable(_$AppDatabase db) =>
      db.planBlocks.createAlias('reminders__plan_block_id__plan_blocks__id');

  $$PlanBlocksTableProcessedTableManager? get planBlockId {
    final $_column = $_itemColumn<String>('plan_block_id');
    if ($_column == null) return null;
    final manager = $$PlanBlocksTableTableManager(
      $_db,
      $_db.planBlocks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_planBlockIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$RemindersTableFilterComposer
    extends Composer<_$AppDatabase, $RemindersTable> {
  $$RemindersTableFilterComposer({
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

  ColumnFilters<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get offsetMinutes => $composableBuilder(
    column: $table.offsetMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get triggerAt => $composableBuilder(
    column: $table.triggerAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deliveredAt => $composableBuilder(
    column: $table.deliveredAt,
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

  $$CalendarEventsTableFilterComposer get eventId {
    final $$CalendarEventsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.eventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableFilterComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$TasksTableFilterComposer get taskId {
    final $$TasksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlanBlocksTableFilterComposer get planBlockId {
    final $$PlanBlocksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.planBlockId,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableFilterComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RemindersTableOrderingComposer
    extends Composer<_$AppDatabase, $RemindersTable> {
  $$RemindersTableOrderingComposer({
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

  ColumnOrderings<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get offsetMinutes => $composableBuilder(
    column: $table.offsetMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get triggerAt => $composableBuilder(
    column: $table.triggerAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deliveredAt => $composableBuilder(
    column: $table.deliveredAt,
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

  $$CalendarEventsTableOrderingComposer get eventId {
    final $$CalendarEventsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.eventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableOrderingComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$TasksTableOrderingComposer get taskId {
    final $$TasksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableOrderingComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlanBlocksTableOrderingComposer get planBlockId {
    final $$PlanBlocksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.planBlockId,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableOrderingComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RemindersTableAnnotationComposer
    extends Composer<_$AppDatabase, $RemindersTable> {
  $$RemindersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get targetId =>
      $composableBuilder(column: $table.targetId, builder: (column) => column);

  GeneratedColumn<int> get offsetMinutes => $composableBuilder(
    column: $table.offsetMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get triggerAt =>
      $composableBuilder(column: $table.triggerAt, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deliveredAt => $composableBuilder(
    column: $table.deliveredAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

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

  $$CalendarEventsTableAnnotationComposer get eventId {
    final $$CalendarEventsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.eventId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableAnnotationComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$TasksTableAnnotationComposer get taskId {
    final $$TasksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlanBlocksTableAnnotationComposer get planBlockId {
    final $$PlanBlocksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.planBlockId,
      referencedTable: $db.planBlocks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanBlocksTableAnnotationComposer(
            $db: $db,
            $table: $db.planBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RemindersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RemindersTable,
          Reminder,
          $$RemindersTableFilterComposer,
          $$RemindersTableOrderingComposer,
          $$RemindersTableAnnotationComposer,
          $$RemindersTableCreateCompanionBuilder,
          $$RemindersTableUpdateCompanionBuilder,
          (Reminder, $$RemindersTableReferences),
          Reminder,
          PrefetchHooks Function({
            bool accountId,
            bool eventId,
            bool taskId,
            bool planBlockId,
          })
        > {
  $$RemindersTableTableManager(_$AppDatabase db, $RemindersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RemindersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RemindersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RemindersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> targetType = const Value.absent(),
                Value<String> targetId = const Value.absent(),
                Value<String?> eventId = const Value.absent(),
                Value<String?> taskId = const Value.absent(),
                Value<String?> planBlockId = const Value.absent(),
                Value<int?> offsetMinutes = const Value.absent(),
                Value<int> triggerAt = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> failureCode = const Value.absent(),
                Value<int?> deliveredAt = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RemindersCompanion(
                id: id,
                accountId: accountId,
                targetType: targetType,
                targetId: targetId,
                eventId: eventId,
                taskId: taskId,
                planBlockId: planBlockId,
                offsetMinutes: offsetMinutes,
                triggerAt: triggerAt,
                state: state,
                failureCode: failureCode,
                deliveredAt: deliveredAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String accountId,
                required String targetType,
                required String targetId,
                Value<String?> eventId = const Value.absent(),
                Value<String?> taskId = const Value.absent(),
                Value<String?> planBlockId = const Value.absent(),
                Value<int?> offsetMinutes = const Value.absent(),
                required int triggerAt,
                required String state,
                Value<String?> failureCode = const Value.absent(),
                Value<int?> deliveredAt = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => RemindersCompanion.insert(
                id: id,
                accountId: accountId,
                targetType: targetType,
                targetId: targetId,
                eventId: eventId,
                taskId: taskId,
                planBlockId: planBlockId,
                offsetMinutes: offsetMinutes,
                triggerAt: triggerAt,
                state: state,
                failureCode: failureCode,
                deliveredAt: deliveredAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$RemindersTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                accountId = false,
                eventId = false,
                taskId = false,
                planBlockId = false,
              }) {
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
                                    referencedTable: $$RemindersTableReferences
                                        ._accountIdTable(db),
                                    referencedColumn: $$RemindersTableReferences
                                        ._accountIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }
                        if (eventId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.eventId,
                                    referencedTable: $$RemindersTableReferences
                                        ._eventIdTable(db),
                                    referencedColumn: $$RemindersTableReferences
                                        ._eventIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }
                        if (taskId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.taskId,
                                    referencedTable: $$RemindersTableReferences
                                        ._taskIdTable(db),
                                    referencedColumn: $$RemindersTableReferences
                                        ._taskIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }
                        if (planBlockId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.planBlockId,
                                    referencedTable: $$RemindersTableReferences
                                        ._planBlockIdTable(db),
                                    referencedColumn: $$RemindersTableReferences
                                        ._planBlockIdTable(db)
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

typedef $$RemindersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RemindersTable,
      Reminder,
      $$RemindersTableFilterComposer,
      $$RemindersTableOrderingComposer,
      $$RemindersTableAnnotationComposer,
      $$RemindersTableCreateCompanionBuilder,
      $$RemindersTableUpdateCompanionBuilder,
      (Reminder, $$RemindersTableReferences),
      Reminder,
      PrefetchHooks Function({
        bool accountId,
        bool eventId,
        bool taskId,
        bool planBlockId,
      })
    >;
typedef $$UndoSlotTableCreateCompanionBuilder =
    UndoSlotCompanion Function({
      Value<int> slot,
      required String commandId,
      required String payload,
      Value<int?> expiresAt,
      required int createdAt,
    });
typedef $$UndoSlotTableUpdateCompanionBuilder =
    UndoSlotCompanion Function({
      Value<int> slot,
      Value<String> commandId,
      Value<String> payload,
      Value<int?> expiresAt,
      Value<int> createdAt,
    });

class $$UndoSlotTableFilterComposer
    extends Composer<_$AppDatabase, $UndoSlotTable> {
  $$UndoSlotTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get slot => $composableBuilder(
    column: $table.slot,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get commandId => $composableBuilder(
    column: $table.commandId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$UndoSlotTableOrderingComposer
    extends Composer<_$AppDatabase, $UndoSlotTable> {
  $$UndoSlotTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get slot => $composableBuilder(
    column: $table.slot,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get commandId => $composableBuilder(
    column: $table.commandId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$UndoSlotTableAnnotationComposer
    extends Composer<_$AppDatabase, $UndoSlotTable> {
  $$UndoSlotTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get slot =>
      $composableBuilder(column: $table.slot, builder: (column) => column);

  GeneratedColumn<String> get commandId =>
      $composableBuilder(column: $table.commandId, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<int> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$UndoSlotTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $UndoSlotTable,
          UndoSlotData,
          $$UndoSlotTableFilterComposer,
          $$UndoSlotTableOrderingComposer,
          $$UndoSlotTableAnnotationComposer,
          $$UndoSlotTableCreateCompanionBuilder,
          $$UndoSlotTableUpdateCompanionBuilder,
          (
            UndoSlotData,
            BaseReferences<_$AppDatabase, $UndoSlotTable, UndoSlotData>,
          ),
          UndoSlotData,
          PrefetchHooks Function()
        > {
  $$UndoSlotTableTableManager(_$AppDatabase db, $UndoSlotTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UndoSlotTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UndoSlotTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UndoSlotTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> slot = const Value.absent(),
                Value<String> commandId = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<int?> expiresAt = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
              }) => UndoSlotCompanion(
                slot: slot,
                commandId: commandId,
                payload: payload,
                expiresAt: expiresAt,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> slot = const Value.absent(),
                required String commandId,
                required String payload,
                Value<int?> expiresAt = const Value.absent(),
                required int createdAt,
              }) => UndoSlotCompanion.insert(
                slot: slot,
                commandId: commandId,
                payload: payload,
                expiresAt: expiresAt,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$UndoSlotTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $UndoSlotTable,
      UndoSlotData,
      $$UndoSlotTableFilterComposer,
      $$UndoSlotTableOrderingComposer,
      $$UndoSlotTableAnnotationComposer,
      $$UndoSlotTableCreateCompanionBuilder,
      $$UndoSlotTableUpdateCompanionBuilder,
      (
        UndoSlotData,
        BaseReferences<_$AppDatabase, $UndoSlotTable, UndoSlotData>,
      ),
      UndoSlotData,
      PrefetchHooks Function()
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
  $$CourseSeriesTableTableManager get courseSeries =>
      $$CourseSeriesTableTableManager(_db, _db.courseSeries);
  $$CalendarEventSeriesTableTableManager get calendarEventSeries =>
      $$CalendarEventSeriesTableTableManager(_db, _db.calendarEventSeries);
  $$CalendarEventsTableTableManager get calendarEvents =>
      $$CalendarEventsTableTableManager(_db, _db.calendarEvents);
  $$CalendarEventOccurrenceExceptionsTableTableManager
  get calendarEventOccurrenceExceptions =>
      $$CalendarEventOccurrenceExceptionsTableTableManager(
        _db,
        _db.calendarEventOccurrenceExceptions,
      );
  $$UserOverlaysTableTableManager get userOverlays =>
      $$UserOverlaysTableTableManager(_db, _db.userOverlays);
  $$TasksTableTableManager get tasks =>
      $$TasksTableTableManager(_db, _db.tasks);
  $$PlanBlocksTableTableManager get planBlocks =>
      $$PlanBlocksTableTableManager(_db, _db.planBlocks);
  $$TaskEventLinksTableTableManager get taskEventLinks =>
      $$TaskEventLinksTableTableManager(_db, _db.taskEventLinks);
  $$ScheduleRelationsTableTableManager get scheduleRelations =>
      $$ScheduleRelationsTableTableManager(_db, _db.scheduleRelations);
  $$ScheduleRelationRulesTableTableManager get scheduleRelationRules =>
      $$ScheduleRelationRulesTableTableManager(_db, _db.scheduleRelationRules);
  $$RemindersTableTableManager get reminders =>
      $$RemindersTableTableManager(_db, _db.reminders);
  $$UndoSlotTableTableManager get undoSlot =>
      $$UndoSlotTableTableManager(_db, _db.undoSlot);
}
